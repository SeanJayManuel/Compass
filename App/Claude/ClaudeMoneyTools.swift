import Core
import Foundation
import SwiftData

/// Claude's read tools for money: overview, net worth, accounts, goals,
/// contributions, the monthly review and the budget.
extension ClaudeTools {
    // MARK: - Money

    var stillWorking: [String: Any] { ["note": "Compass is still working out net worth; ask again in a moment."] }

    var netWorthSeries: [DailyTotal] { netWorth.breakdown.map(\.netWorth) }

    func overview() throws -> [String: Any] {
        guard let latest = netWorth.breakdown.last else { return stillWorking }
        let series = netWorthSeries
        let accounts = try store.accounts()
        let active = accounts.filter { account in account.archivedOn.map { $0 > today } ?? true }
        let monthAgo = today.addingMonths(-1), janFirst = Day(year: today.year, month: 1, day: 1)
        var answer: [String: Any] = [
            "date": iso(latest.day), "netWorth": dollars(latest.total), "outsideRetirement": dollars(latest.accessible),
            "changeSinceMonthAgo": ["since": iso(monthAgo), "amount": dollars(NetWorthSeries.change(in: series, since: monthAgo))],
            "changeSinceJan1": dollars(NetWorthSeries.change(in: series, since: janFirst)),
            "accountsStatus": AccountsBreakdown.staleSummary(active, latest: netWorth.latest, today: today),
            "allocation": NetWorthSeries.allocation(latest).map {
                ["class": $0.accountClass.rawValue, "amount": dollars($0.amount), "share": fraction($0.share)]
            }
        ]
        let plan = try store.budgetPlan(for: Month(today))
        if plan.flexibleBudget > 0 {
            let month = Month(today)
            let kinds = try store.kinds()
            let transactions = TransferMatch.asFiled(try monthTransactions(month, monthsBefore: 1), kinds: kinds)
            let pace = FlexBudget.month(month, today: today, transactions: transactions, kinds: kinds, plan: plan)
            answer["flexibleSpending"] = [
                "month": monthText(month), "budget": dollars(pace.flexibleBudget), "spent": dollars(pace.flexibleSpent),
                "left": dollars(pace.flexibleRemaining), "evenPaceSoFar": dollars(pace.expectedSoFar), "overPace": pace.isOverPace
            ]
        }
        let profile = try store.payProfile()
        if profile.isSet {
            answer["savingsRate"] = try savingsRates(profile)
            answer["upcomingPay"] = Pay.upcoming(profile, today: today).map(expectedRow)
        }
        let goals = try store.goals()
        answer["goalsNeedingALook"] = GoalAttention.order(goals, progress: netWorth.goalProgress).prefix(4).map { goal in
            goalSummary(goal, progress: netWorth.goalProgress[goal.id])
        }
        return answer
    }

    func netWorthNow() -> [String: Any] {
        guard let latest = netWorth.breakdown.last else { return stillWorking }
        let series = netWorthSeries
        var changes: [String: Any] = [:]
        for range in TimeRange.allCases {
            guard let start = range.start(endingOn: today) else { continue }
            changes[range.rawValue] = ["since": iso(start), "amount": dollars(NetWorthSeries.change(in: series, since: start))]
        }
        return [
            "date": iso(latest.day), "total": dollars(latest.total),
            "outsideRetirement": dollars(latest.accessible), "byClass": byClass(latest.byClass), "change": changes
        ]
    }

    func netWorthHistory(_ args: Arguments) throws -> [String: Any] {
        guard !netWorth.breakdown.isEmpty else { return stillWorking }
        let range = try args.range()
        let by = try args.choice("by", in: ["day", "week", "month"]) ?? "day"
        let split = try args.choice("split", in: ["total", "class"]) ?? "total"
        let start = range.start(endingOn: today)
        let visible = netWorth.breakdown.filter { day in start.map { day.day >= $0 } ?? true }
        let points = by == "day" ? NetWorthSeries.averaged(visible, toAtMost: Self.pointLimit) : periodEnds(visible, by: by) { $0.day }
        var answer: [String: Any] = [
            "range": range.rawValue, "by": by,
            "points": points.map { point -> [String: Any] in
                var row: [String: Any] = ["date": iso(point.day), "total": dollars(point.total)]
                if split == "class" { row["byClass"] = byClass(point.byClass) }
                return row
            }
        ]
        if by == "day", visible.count > Self.pointLimit {
            answer["note"] = "Each point averages the days from its date to the next, as the chart draws it; the last is today's exact value."
        }
        if by == "month" {
            // What accounts linked in each month brought in, left out of its change.
            let series = netWorthSeries
            var openedByMonth: [Month: Decimal] = [:], previous = series.first?.opened ?? 0
            for point in series {
                openedByMonth[Month(point.day), default: 0] += point.opened - previous
                previous = point.opened
            }
            answer["monthlyChange"] = NetWorthSeries.monthlyChange(series, from: start).map { change -> [String: Any] in
                var row: [String: Any] = ["month": monthText(change.month), "change": dollars(change.total)]
                if let opened = openedByMonth[change.month], opened != 0 { row["openingBalances"] = dollars(opened) }
                return row
            }
        }
        return answer
    }

    func accounts(_ args: Arguments) async throws -> [String: Any] {
        let includeArchived = try args.bool("include_archived") ?? false
        let money = await load(snapshots: true)
        let monthAgo = today.addingMonths(-1), yearAgo = today.addingMonths(-12)
        let byAccount = Dictionary(grouping: money.snapshots, by: \.accountID)
        let shown = money.accounts.filter { includeArchived || ($0.archivedOn.map { $0 > today } ?? true) }
        return [
            "date": iso(today),
            "accounts": shown.map { account -> [String: Any] in
                let latest = netWorth.latest[account.id]
                let measure = BalanceHistoryMeasure(account.accountClass)
                let series = NetWorthSeries.accountSeries(account, snapshots: byAccount[account.id] ?? [], through: today)
                var row: [String: Any] = [
                    "id": account.id.uuidString, "name": Self.displayName(account.name), "class": account.accountClass.rawValue,
                    "measure": measure == .owed ? "owed" : "balance",
                    "balance": dollars(latest.map { measure.drawn($0.balance) }),
                    "lastUpdated": latest.map { iso($0.day) } ?? NSNull(),
                    "updatedBy": latest.map { $0.source == .simplefin ? "sync" : $0.source == .manual ? "hand" : "import" } ?? NSNull(),
                    "synced": account.source == .simplefin,
                    "change1M": dollars(NetWorthSeries.change(in: series, since: monthAgo)),
                    "change1Y": dollars(NetWorthSeries.change(in: series, since: yearAgo)),
                    "countedInNetWorth": !account.excludedFromNetWorth
                ]
                switch Staleness.freshness(source: account.source, lastUpdated: latest?.day, today: today) {
                case .current: row["freshness"] = "current"
                case .stale(let days): row["freshness"] = "out of date (\(days) days)"
                case .noBalance: row["freshness"] = "no balance yet"
                }
                if let archivedOn = account.archivedOn { row["archivedOn"] = iso(archivedOn) }
                return row
            }
        ]
    }

    func accountHistory(_ args: Arguments) async throws -> [String: Any] {
        let money = await load(snapshots: true)
        let account = try find(try args.required("account"), in: money.accounts)
        let range = try args.range()
        let by = try args.choice("by", in: ["day", "week", "month"]) ?? "day"
        let series = NetWorthSeries.accountSeries(account, snapshots: money.snapshots.filter { $0.accountID == account.id }, through: today)
        let visible = NetWorthSeries.trim(series, to: range, endingOn: series.last?.day ?? today)
        let points = by == "day" ? NetWorthSeries.averaged(visible, toAtMost: Self.pointLimit) : periodEnds(visible, by: by) { $0.day }
        return [
            "account": Self.displayName(account.name), "measure": BalanceHistoryMeasure(account.accountClass) == .owed ? "owed" : "balance",
            "range": range.rawValue, "by": by,
            "points": points.map { ["date": iso($0.day), "value": dollars($0.total)] }
        ]
    }

    func goals() throws -> [String: Any] {
        let goals = try store.goals()
        let accounts = try store.accounts()
        let ledger = try store.goalLedger()
        let order = GoalAttention.order(goals, progress: netWorth.goalProgress).map(\.id)
        let sorted = goals.sorted { (order.firstIndex(of: $0.id) ?? .max, $0.name) < (order.firstIndex(of: $1.id) ?? .max, $1.name) }
        return [
            "goals": sorted.map { goal -> [String: Any] in
                var row = goalSummary(goal, progress: netWorth.goalProgress[goal.id])
                switch goal.kind {
                case .netWorth: row["measures"] = "net worth"
                case .accountTotal(let ids): row["measures"] = accounts.filter { ids.contains($0.id) }.map { Self.displayName($0.name) }
                case .fire(let spending, let multiplier):
                    row["measures"] = "investable assets (FIRE)"
                    row["annualSpending"] = dollars(spending)
                    row["multiplier"] = "\(multiplier)"
                }
                if !goal.note.isEmpty { row["note"] = goal.note }
                if let targetMin = goal.targetMin { row["targetMin"] = dollars(targetMin) }
                if let targetDate = goal.targetDate { row["targetDate"] = iso(targetDate) }
                if let reward = goal.reward {
                    row["reward"] = rewardRow(reward)
                }
                if let progress = netWorth.goalProgress[goal.id] {
                    row["remaining"] = dollars(progress.remaining)
                    row["pacePerMonth"] = dollars(progress.pacePerMonth)
                    if progress.paceFromContributions {
                        let month = Month(today)
                        row["paceBasis"] = "contributions, \(monthText(month.adding(-3))) to \(monthText(month.adding(-1)))"
                        row["marketPerMonth"] = dollars(progress.marketPerMonth)
                        if !progress.paceLeavesOut.isEmpty {
                            row["paceLeavesOut"] = accounts.filter { progress.paceLeavesOut.contains($0.id) }.map { Self.displayName($0.name) }
                        }
                    } else {
                        row["paceBasis"] = "balances, last three months"
                    }
                    row["neededPerMonth"] = dollars(progress.neededPerMonth)
                    row["projectedDate"] = progress.projectedDate.map(iso) ?? NSNull()
                    row["minimumReached"] = progress.minimumReached
                }
                if GoalFunding.canPay(goal, accounts: accounts) { row["canPayForThings"] = true }
                let paid = ledger.paid(by: goal.id)
                if !paid.isEmpty {
                    // Current already leaves out what's still to move: it's what's left to spend.
                    row["toMove"] = dollars(ledger.toMove(goal.id, on: today))
                    row["paidFor"] = paid.suffix(10).reversed().map {
                        ["date": iso($0.day), "merchant": $0.merchant, "amount": dollars($0.paidByGoal), "transaction": $0.id.uuidString]
                    }
                }
                return row
            },
            "milestones": GoalLifecycle.milestones(in: goals).map { milestone -> [String: Any] in
                var row: [String: Any] = [
                    "goal": milestone.goal.name, "date": iso(milestone.day),
                    "kind": milestone.kind == .reached ? "reached" : "reward claimed"
                ]
                if let months = milestone.monthsSincePrevious, let previous = milestone.previousName {
                    row["monthsSincePrevious"] = months
                    row["previous"] = previous
                }
                return row
            }
        ]
    }

    func goalHistory(_ args: Arguments) async throws -> [String: Any] {
        let wanted = try args.required("goal")
        let goals = try store.goals()
        guard
            let goal = goals.first(where: { $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame })
                ?? goals.first(where: { $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame })
        else {
            throw Problem("No goal called \(wanted). Names: \(goals.map(\.name).joined(separator: ", ")).")
        }
        let range = try args.range()
        let series = await netWorth.series(for: goal)
        let points = NetWorthSeries.averaged(NetWorthSeries.trim(series, to: range, endingOn: today), toAtMost: 240)
        return [
            "goal": goal.name, "target": dollars(goal.effectiveTarget), "range": range.rawValue,
            "points": points.map { ["date": iso($0.day), "value": dollars($0.total)] }
        ]
    }

    func contributions(_ args: Arguments) async throws -> [String: Any] {
        let to = try args.month("to") ?? Month(today)
        let from = try args.month("from") ?? to.adding(-11)
        guard from <= to else { throw Problem("from must not be after to.") }
        let money = await load(snapshots: true, transactions: true)
        var report = Contributions.report(
            accounts: money.accounts, snapshots: money.snapshots, transactions: money.transactions,
            kinds: try store.kinds(), today: today, months: from...to,
            payroll: try store.payroll(months: from...to, today: today))
        if let wanted = args.string("account") {
            let account = try find(wanted, in: money.accounts)
            report = report.filter { $0.accountID == account.id }
        }
        let names = Dictionary(uniqueKeysWithValues: money.accounts.map { ($0.id, $0) })
        var totals: [Month: [ContributionMonth]] = [:]
        for account in report { for month in account.months { totals[month.month, default: []].append(month) } }
        return [
            "accounts": report.map { account -> [String: Any] in
                [
                    "name": Self.displayName(names[account.accountID]?.name ?? ""),
                    "class": names[account.accountID]?.accountClass.rawValue ?? "",
                    "months": account.months.map(contributionRow)
                ]
            },
            "totals": totals.keys.sorted().map { month -> [String: Any] in
                let months = totals[month]!
                return [
                    "month": monthText(month), "monthToDate": month == Month(today),
                    "contributions": dollars(months.compactMap(\.netContributions).reduce(0, +)),
                    "marketChange": dollars(months.compactMap(\.marketChange).reduce(0, +)),
                    "accountsUntold": months.filter { $0.marketChange == nil }.count,
                    "note": "Over the accounts where contributions and market change can be told."
                ]
            }
        ]
    }

    func contributionRow(_ month: ContributionMonth) -> [String: Any] {
        var row: [String: Any] = [
            "month": monthText(month.month), "monthToDate": month.isMonthToDate,
            "startingBalance": dollars(month.startingBalance), "endingBalance": dollars(month.endingBalance),
            "moneyIn": dollars(month.moneyIn), "moneyOut": dollars(month.moneyOut),
            "netContributions": dollars(month.netContributions), "marketChange": dollars(month.marketChange)
        ]
        if month.unclear > 0 { row["unclear"] = month.unclear }
        if let pay = month.payroll {
            row["fromPay"] = ["employee": dollars(pay.employee), "employer": dollars(pay.employer), "estimated": pay.estimated] as [String: Any]
        }
        if month.hasBalanceGap {
            row["note"] = "No balance recorded this month."
        } else if month.startingBalance == nil {
            row["note"] = "Balances start this month."
        } else if month.unclear > 0 {
            row["note"] = "Some of the account's transactions can't be told apart from trades, so contributions are unknown."
        } else if month.moneyIn == nil {
            row["note"] = "The account's own transactions don't cover this month, and their pay settings can't tell every payday."
        } else if let pay = month.payroll {
            row["note"] =
                pay.estimated
                ? "By paycheck, split theirs and the employer's by their pay settings; a paycheck with no buys synced is the settings' expected amount (estimated)."
                : "By paycheck, split theirs and the employer's by their pay settings."
        }
        return row
    }

    func monthlyReview(_ args: Arguments) async throws -> [String: Any] {
        let month = try args.month("month") ?? Month(today)
        guard month <= Month(today) else { throw Problem("That month hasn't started.") }
        let money = await load(snapshots: true, transactions: true)
        let goals = try store.goals()
        let kinds = try store.kinds()
        let review = MonthlyReview.make(
            month: month, today: today, accounts: money.accounts, snapshots: money.snapshots,
            breakdown: netWorth.breakdown, transactions: TransferMatch.asFiled(money.transactions, kinds: kinds),
            kinds: kinds, plan: try store.budgetPlan(for: month),
            goals: goals.filter { goal in
                if case .achieved(let on, _) = goal.status { return on >= month.firstDay }
                return goal.status == .active
            },
            payroll: try store.payroll(months: month...month, today: today))
        let names = Dictionary(uniqueKeysWithValues: money.accounts.map { ($0.id, Self.displayName($0.name)) })
        let goalNames = Dictionary(uniqueKeysWithValues: goals.map { ($0.id, $0.name) })
        let flexible = review.flexible
        return [
            "month": monthText(month), "monthToDate": review.isMonthToDate, "through": iso(review.through),
            "netWorth": [
                "start": dollars(review.netWorthStart), "end": dollars(review.netWorthEnd), "change": dollars(review.netWorthChange),
                "openingBalances": dollars(review.openingBalances),
                "marketChange": dollars(review.marketChange), "everythingElse": dollars(review.otherChange),
                "note":
                    "Market change covers the investing accounts where it can be told; everything else is saving, spending, debt and the accounts listed as untold. Moving money into investing doesn't change net worth. Change leaves out opening balances: what accounts linked this month already held."
            ] as [String: Any],
            "investing": [
                "contributions": dollars(review.contributions), "marketChange": dollars(review.marketChange),
                "untold": review.untold.map { names[$0] ?? "" },
                "accounts": review.investing.map { month -> [String: Any] in
                    var row = contributionRow(month)
                    row["name"] = names[month.accountID] ?? ""
                    return row
                }
            ] as [String: Any],
            "flexibleSpending": [
                "budget": dollars(flexible.flexibleBudget), "spent": dollars(flexible.flexibleSpent),
                "left": dollars(flexible.flexibleRemaining), "evenPaceSoFar": dollars(flexible.expectedSoFar)
            ],
            "fixedBills": [
                "paid": dollars(flexible.fixedPaid), "expected": dollars(flexible.fixedExpected),
                "bills": flexible.bills.map(billRow)
            ] as [String: Any],
            "income": ["actual": dollars(review.income), "planned": dollars(review.plannedIncome)],
            "savingsRate": try savingsRate(month)
                ?? ["note": try store.payProfile().isSet ? "No paycheck has arrived this month yet." : Self.payNotSet],
            "categoriesFurthestFromUsual": review.categories.prefix(6).map { category -> [String: Any] in
                var row: [String: Any] = [
                    "category": category.category, "thisMonth": dollars(category.thisMonth),
                    "usual": dollars(category.usual), "difference": dollars(category.difference)
                ]
                // Their notes on the month's charges there, so the why sits beside the what.
                let noted = money.transactions.filter { transaction in
                    Month(transaction.day) == month && (transaction.category ?? Spending.uncategorized) == category.category
                        && (!transaction.note.isEmpty || transaction.oneOff || transaction.reimbursable)
                }
                if !noted.isEmpty {
                    row["notes"] = noted.sorted { $0.day < $1.day }.map { transaction -> [String: Any] in
                        var note: [String: Any] = [
                            "date": iso(transaction.day), "merchant": transaction.merchant,
                            "amount": dollars(transaction.amount), "note": transaction.note, "oneOff": transaction.oneOff
                        ]
                        if transaction.reimbursable { note["owedBack"] = dollars(transaction.owedBack) }
                        return note
                    }
                }
                return row
            },
            "goals": review.goals.map { movement -> [String: Any] in
                var row: [String: Any] = [
                    "goal": goalNames[movement.goalID] ?? "", "start": dollars(movement.start),
                    "end": dollars(movement.end), "change": dollars(movement.change)
                ]
                if movement.openingBalances != 0 { row["openingBalances"] = dollars(movement.openingBalances) }
                return row
            }
        ]
    }

    func budget(_ args: Arguments) throws -> [String: Any] {
        let month = try args.month("month") ?? Month(today)
        let kinds = try store.kinds(), plan = try store.budgetPlan(for: month)
        // Matched transfers read as filed, as on Spending's budget.
        let transactions = TransferMatch.asFiled(try monthTransactions(month, monthsBefore: 1), kinds: kinds)
        let accounts = try store.accounts()
        let ledger = try store.goalLedger(kinds: kinds)
        let sheet = FlexBudget.sheet(month, transactions: transactions, kinds: kinds, plan: plan, settling: ledger.settling)
        let pace = FlexBudget.month(month, today: today, transactions: transactions, kinds: kinds, plan: plan)
        let names = Dictionary(accounts.map { ($0.id.uuidString, $0.name) }, uniquingKeysWith: { first, _ in first })
        let goalNames = Dictionary(try store.goals().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let profile = try store.payProfile(), paychecks = try store.paychecks(profile)
        let fromPay = Pay.plansIncome(month: month, profile: profile, paychecks: paychecks)
        func group(_ group: BudgetGroup) -> [String: Any] {
            [
                "planned": dollars(group.planned), "actual": dollars(group.actual), "outstanding": dollars(group.outstanding),
                "lines": (group.lines + group.unbudgeted).map {
                    ["category": $0.category, "planned": dollars($0.planned), "actual": dollars($0.actual)]
                }
            ]
        }
        var incomeGroup = group(sheet.income)
        if fromPay {
            incomeGroup["paychecks"] =
                [
                    "category": profile.incomeCategory, "planned": Pay.plannedPaychecks(profile),
                    "latestNet": (Pay.latestNet(paychecks, through: month.lastDay)?.net).map(dollars) ?? NSNull(),
                    "paydays": Pay.paydays(in: month, profile: profile).map(iso),
                    "note": Pay.incomeNote(month: month, profile: profile, paychecks: paychecks)
                ] as [String: Any]
        }
        return [
            "month": monthText(month), "monthToDate": month == Month(today),
            "income": incomeGroup, "fixed": group(sheet.fixed),
            "irregular": group(sheet.irregular),
            "flexible": [
                "budget": dollars(sheet.flexible.budget), "actual": dollars(sheet.flexible.actual),
                "remaining": dollars(sheet.flexible.remaining),
                "lines": sheet.flexible.lines.map { ["category": $0.category, "actual": dollars($0.actual)] }
            ] as [String: Any],
            // Money moved into their savings and investing accounts: a job for income, not an expense.
            "savings": [
                "planned": dollars(sheet.savings.planned), "actual": dollars(sheet.savings.actual),
                "lines": (sheet.savings.lines + sheet.savings.unbudgeted).map { line -> [String: Any] in
                    var row: [String: Any] = [
                        "account": names[line.category] ?? "Unknown account",
                        "planned": dollars(line.planned), "actual": dollars(line.actual)
                    ]
                    if month <= Month(today), let planned = line.planned, line.actual < planned { row["short"] = dollars(planned - line.actual) }
                    return row
                }
            ] as [String: Any],
            "leftToBudget": dollars(sheet.leftToBudget),
            "plannedNet": dollars(sheet.plannedNet), "actualNet": dollars(sheet.actualNet),
            "unfiledMoneyIn": dollars(sheet.unfiledIn),
            // Spending a goal paid for: in Spending, out of the expenses, as the move out of its fund is out of savings.
            "paidFromGoals": sheet.paidFromGoals.sorted { $0.value > $1.value }.map {
                ["goal": goalNames[$0.key] ?? "A goal", "amount": dollars($0.value)]
            },
            "pace": [
                "daysLeft": pace.daysLeft, "evenPaceSoFar": dollars(pace.expectedSoFar), "overPace": pace.isOverPace,
                "dailyAllowance": dollars(pace.dailyAllowance)
            ] as [String: Any],
            "bills": pace.bills.map(billRow)
        ]
    }
}

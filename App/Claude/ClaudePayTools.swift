import Core
import Foundation
import SwiftData

/// Claude's read tools for pay, spending, transactions and categories.
extension ClaudeTools {
    // MARK: - Pay

    static let payNotSet = "Pay isn't set up: their salary and one payday go in Settings › Pay (a paystub can fill them in, but none is needed)."

    func pay() throws -> [String: Any] {
        let profile = try store.payProfile(), paychecks = try store.paychecks(profile)
        let accounts = try store.accounts()
        func name(_ id: UUID?) -> Any { id.flatMap { id in accounts.first { $0.id == id } }.map { Self.displayName($0.name) } ?? NSNull() }
        var answer: [String: Any] = [
            "settings": [
                "annualSalary": dollars(profile.annualSalary), "paidEveryDays": profile.everyDays,
                "knownPayday": profile.knownPayday.map(iso) ?? NSNull(),
                "retirementPercent": "\(profile.retirementPercent)", "retirementPreTax": profile.retirementPreTax,
                "matchPercentOfHisContribution": "\(profile.matchPercent)", "matchUpToPercentOfPay": "\(profile.matchUpToPercent)",
                "stockPurchasePerCheck": dollars(profile.stockPerCheck), "stockCompanyPerCheck": dollars(profile.stockCompanyPerCheck),
                "retirementAccount": name(profile.retirementAccountID), "stockAccount": name(profile.stockAccountID),
                "paycheckCategory": profile.incomeCategory, "paychecksPlannedInBudget": profile.planIncomeFromPay
            ] as [String: Any],
            "upcoming": Pay.upcoming(profile, today: today).map(expectedRow),
            "upcomingNote": "Bonuses and vests are kept apart from the monthly budget.",
            "budget":
                "The budget plans \(Pay.plannedPaychecks(profile)) paychecks a month at the latest net deposit; an extra payday, bonuses and the stock plan stay out."
        ]
        if let latest = Pay.latestNet(paychecks) {
            answer["latestPaycheck"] = ["arrived": iso(latest.day), "payday": iso(latest.payday), "net": dollars(latest.net)]
            answer["monthlyTakeHome"] = dollars(Pay.monthlyTakeHome(net: latest.net, profile: profile))
            answer["monthlyTakeHomeNote"] = "The latest net paycheck × \(Pay.paydaysPerYear(profile)) / 12."
        } else {
            answer["latestPaycheck"] = NSNull()
            answer["latestPaycheckNote"] = "No deposit filed as \(profile.incomeCategory) near a payday yet."
        }
        guard let check = Pay.expected(profile) else {
            answer["note"] = Self.payNotSet
            return answer
        }
        answer["annualGross"] = dollars(profile.annualSalary)
        answer["perPaycheck"] =
            [
                "gross": dollars(check.regular),
                "retirement": ["employee": dollars(check.retirement), "match": dollars(check.match), "total": dollars(check.retirementTotal)],
                "stockPurchase": ["employee": dollars(check.stockPurchase), "company": dollars(check.companyStock), "total": dollars(check.stockTotal)]
            ] as [String: Any]
        let upcoming = Pay.upcomingPaydays(profile, after: today, months: 6)
        answer["upcomingPaydays"] = Dictionary(grouping: upcoming, by: Month.init).sorted { $0.key < $1.key }.map { month, days -> [String: Any] in
            let all = Pay.paydays(in: month, profile: profile)
            return ["month": monthText(month), "paydays": days.map(iso), "paydaysInMonth": all.count, "threePaychecks": all.count >= 3]
        }
        answer["threePaycheckMonths"] = Pay.threePaycheckMonths(from: Month(today), months: 18, profile: profile).map(monthText)
        answer["savingsRate"] = try savingsRates(profile)
        let stubs = try store.paystubs()
        if !stubs.isEmpty { answer["stubsImported"] = stubs.map { iso($0.depositDate) } }
        return answer
    }

    func expectedRow(_ item: ExpectedPay) -> [String: Any] {
        var row: [String: Any] = [
            "id": item.id.uuidString, "kind": item.kind.rawValue, "title": item.title, "gross": dollars(item.gross),
            "date": item.day.map(iso) ?? NSNull(), "inMonthlyBudget": false
        ]
        if let month = item.month {
            row["month"] = String(format: "%04d-%02d", month.year, month.month)
        } else if item.day == nil {
            row["dateNote"] = "Not known yet."
        }
        if item.estimate { row["estimate"] = true }
        if !item.note.isEmpty { row["note"] = item.note }
        return row
    }

    /// What they moved into savings and investing each month: every transfer
    /// from their everyday accounts into a saving one, budgeted or not.
    func movedByMonth(_ profile: PayProfile) throws -> [Month: Decimal] {
        let kinds = try store.kinds(), transactions = try store.transactions()
        let saving = SavingsRate.savingAccounts(try store.accounts(), transactions: transactions, kinds: kinds, profile: profile)
        return SavingsRate.moved(
            transactions, kinds: kinds, into: saving, profile: profile,
            settling: try store.goalLedger(transactions: transactions, kinds: kinds).settling)
    }

    func rateRow(_ rate: SavingsRate) -> [String: Any] {
        [
            "ofGross": rate.ofGross.map(fraction) ?? NSNull(), "ofTakeHome": rate.ofTakeHome.map(fraction) ?? NSNull(),
            "saved": dollars(rate.saved), "earned": dollars(rate.earned),
            "movedToSavings": dollars(rate.moved), "takeHome": dollars(rate.takeHome)
        ]
    }

    /// A month's savings rate from their settings, once a paycheck has arrived in it.
    func savingsRate(_ month: Month) throws -> [String: Any]? {
        let profile = try store.payProfile(), paychecks = try store.paychecks(profile)
        guard paychecks.contains(where: { Month($0.payday) == month }),
            let rate = SavingsRate.month(
                month, profile: profile, paychecks: paychecks,
                moved: try movedByMonth(profile)[month] ?? 0, today: today)
        else { return nil }
        var row = rateRow(rate)
        row["month"] = monthText(month)
        row["paydays"] = Pay.paydays(in: month, profile: profile).filter { $0 <= today }.count
        return row
    }

    /// The last 12 full months and the year so far, over months a paycheck arrived in.
    func savingsRates(_ profile: PayProfile) throws -> [String: Any] {
        let paychecks = try store.paychecks(profile)
        // The trailing year and this year share most months: each is worked out once.
        var monthRates: [Month: SavingsRate] = [:]
        let moved = try movedByMonth(profile)
        func rates(_ months: [Month]) throws -> (SavingsRate, [Month]) {
            var rates: [SavingsRate] = [], counted: [Month] = []
            for month in months where paychecks.contains(where: { Month($0.payday) == month }) {
                if monthRates[month] == nil {
                    monthRates[month] = SavingsRate.month(month, profile: profile, paychecks: paychecks, moved: moved[month] ?? 0, today: today)
                }
                guard let rate = monthRates[month] else { continue }
                rates.append(rate)
                counted.append(month)
            }
            return (SavingsRate.total(rates), counted.sorted())
        }
        let (trailing, trailingMonths) = try rates((1...12).map { Month(today).adding(-$0) })
        let (year, yearMonths) = try rates((1...today.month).map { Month(year: today.year, month: $0) })
        var row: [String: Any] = [
            "trailing12Months": trailingMonths.isEmpty ? NSNull() : rateRow(trailing),
            "trailingMonthsCounted": trailingMonths.map(monthText),
            "yearToDate": yearMonths.isEmpty ? NSNull() : rateRow(year),
            "yearToDateMonthsCounted": yearMonths.map(monthText),
            "definition":
                "ofGross: (moved to savings and investing + 401(k) + match + stock purchase + company stock) / (salary + match), per payday from Settings › Pay. Moved is every transfer from their everyday accounts into a savings or investing account (budgeted or not), contributions from accounts Compass can't see, and pay deposited straight into savings, less what went back out of that account to their everyday accounts the same month (never below zero per account); moves between savings accounts, or out of the 401(k) or stock plan, aren't new saving. ofTakeHome: moved / paychecks deposited."
        ]
        if trailingMonths.count < 12 { row["note"] = "Over the months a paycheck arrived in." }
        return row
    }

    func billRow(_ bill: BillStatus) -> [String: Any] {
        [
            "category": bill.category, "expected": dollars(bill.expected), "paid": dollars(bill.paid),
            "status": bill.isPaid ? "paid" : "due", "usualDay": bill.usualDay ?? NSNull()
        ]
    }

    func spending(_ args: Arguments) throws -> [String: Any] {
        let month = try args.month("month") ?? Month(today)
        let transactions = try monthTransactions(month, monthsBefore: 11)
        let kinds = try store.kinds()
        return [
            "month": monthText(month), "monthToDate": month == Month(today),
            "categories": Spending.month(month, transactions: transactions, kinds: kinds).map {
                [
                    "category": $0.category, "thisMonth": dollars($0.thisMonth), "sixMonthAverage": dollars($0.sixMonthAverage),
                    "wellAboveAverage": $0.isWellAboveAverage
                ] as [String: Any]
            },
            "twelveMonths": Spending.monthlyByCategory(endingIn: month, transactions: transactions, kinds: kinds).map { row -> [String: Any] in
                [
                    "category": row.category, "yearTotal": dollars(row.yearTotal),
                    "months": row.months.map { ["month": monthText($0.month), "total": dollars($0.total)] }
                ]
            }
        ]
    }

    func transactions(_ args: Arguments) async throws -> [String: Any] {
        let category: CategoryFilter =
            switch args.string("category") {
            case nil: .any
            case let name? where name.lowercased() == "unfiled": .unfiled
            case let name?: .named(name)
            }
        let query = TransactionQuery(
            text: args.string("text") ?? "", category: category, month: try args.month("month"),
            hasNote: try args.bool("has_note"), oneOff: try args.bool("one_off"),
            reimbursable: try args.bool("reimbursable"), noteText: args.string("note_text") ?? "")
        let from = try args.day("from"), to = try args.day("to")
        let direction = try args.choice("direction", in: ["in", "out"])
        let minimum = try args.amount("min_amount"), maximum = try args.amount("max_amount")
        let limit = min(max(try args.int("limit") ?? 50, 1), 500)
        let money = await load(transactions: true)
        let account = try args.string("account").map { try find($0, in: money.accounts) }
        let names = Dictionary(uniqueKeysWithValues: money.accounts.map { ($0.id, Self.displayName($0.name)) })
        let goalNames = Dictionary(try store.goals().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let matches = TransactionSearch.filter(money.transactions, query).filter { transaction in
            let size = abs(transaction.amount)
            return (account.map { transaction.accountID == $0.id } ?? true)
                && (from.map { transaction.day >= $0 } ?? true) && (to.map { transaction.day <= $0 } ?? true)
                && (direction.map { $0 == "in" ? transaction.amount > 0 : transaction.amount < 0 } ?? true)
                && (minimum.map { size >= $0 } ?? true) && (maximum.map { size <= $0 } ?? true)
        }
        return [
            "count": matches.count, "shown": min(matches.count, limit),
            "transactions": matches.prefix(limit).map { transaction -> [String: Any] in
                var row: [String: Any] = [
                    "id": transaction.id.uuidString, "date": iso(transaction.day), "amount": dollars(transaction.amount),
                    "merchant": transaction.merchant, "statement": transaction.statement,
                    "category": transaction.category ?? NSNull(), "account": names[transaction.accountID] ?? "",
                    "note": transaction.note, "oneOff": transaction.oneOff, "reimbursable": transaction.reimbursable
                ]
                if transaction.reimbursable { row["owedBack"] = dollars(transaction.owedBack) }
                if transaction.isSplit { row["splits"] = transaction.splits.map { ["category": $0.category, "amount": dollars($0.amount)] } }
                if let goal = transaction.paidFromGoal, transaction.paidByGoal > 0 {
                    row["paidFromGoal"] = ["goal": goalNames[goal] ?? "A goal", "amount": dollars(transaction.paidByGoal)]
                }
                return row
            }
        ]
    }

    func categories() throws -> [String: Any] {
        let kinds = try store.kinds(), plan = try store.budgetPlan(for: Month(today))
        let counts = try store.categoryCounts()
        let names = try store.knownCategories().union(counts.keys.compactMap { $0 })
        return [
            "categories": names.sorted().map { name -> [String: Any] in
                let kind = kinds[name] ?? CategoryKind.guess(name)
                var row: [String: Any] = ["name": name, "kind": kind.rawValue, "transactions": counts[name] ?? 0]
                if kind == .spending { row["budgetRole"] = plan.role(of: name).rawValue }
                return row
            },
            "unfiledTransactions": counts[nil] ?? 0
        ]
    }
}

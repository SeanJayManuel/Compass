import Foundation

/// One money line on a paystub: this period and the year to date.
public struct PaystubLine: Hashable, Codable, Sendable {
    public var name: String
    public var current: Decimal
    public var yearToDate: Decimal
    /// Marked * on the stub: taken before tax.
    public var preTax: Bool

    public init(name: String, current: Decimal, yearToDate: Decimal, preTax: Bool = false) {
        self.name = name
        self.current = current
        self.yearToDate = yearToDate
        self.preTax = preTax
    }
}

public enum PaystubProblem: Error, Hashable, Sendable {
    /// No pay period, deposit date or net pay.
    case notAStub
    /// Earnings less taxes and deductions isn't the net pay.
    case doesntAddUp
}

/// A paycheck's Statement of Earnings and Deductions, in one common payroll layout.
/// Only what's read from it is kept, never the file.
public struct Paystub: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var periodStart: Day
    public var periodEnd: Day
    public var depositDate: Day
    public var earnings: [PaystubLine]
    public var taxes: [PaystubLine]
    public var deductions: [PaystubLine]
    public var netPay: Decimal
    public var netPayYearToDate: Decimal

    public init(
        id: UUID = UUID(), periodStart: Day, periodEnd: Day, depositDate: Day, earnings: [PaystubLine],
        taxes: [PaystubLine], deductions: [PaystubLine], netPay: Decimal, netPayYearToDate: Decimal
    ) {
        self.id = id
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.depositDate = depositDate
        self.earnings = earnings
        self.taxes = taxes
        self.deductions = deductions
        self.netPay = netPay
        self.netPayYearToDate = netPayYearToDate
    }

    private func sum(_ lines: [PaystubLine], _ words: [String], yearToDate: Bool = false) -> Decimal {
        lines.filter { line in words.contains { line.name.uppercased().contains($0) } }
            .reduce(0) { $0 + (yearToDate ? $1.yearToDate : $1.current) }
    }

    public var regular: Decimal { sum(earnings, ["REGULAR"]) }
    /// MGMT INCENTIVE, or a line called a bonus.
    public var bonus: Decimal { sum(earnings, Self.bonusWords) }
    public var bonusYearToDate: Decimal { sum(earnings, Self.bonusWords, yearToDate: true) }
    /// The company's 15% on their stock purchase (CO STK CONT): listed as
    /// earnings and taken back as a deduction, so it's never take-home.
    public var companyStock: Decimal { sum(earnings, Self.companyStockWords) }
    public var retirement: Decimal { sum(deductions, Self.retirementWords) }
    public var stockPurchase: Decimal { sum(deductions, Self.stockPurchaseWords) }
    /// Insurance and the like: every deduction but the 401(k) and stock.
    public var benefits: Decimal {
        deductions.reduce(0) { $0 + $1.current } - retirement - stockPurchase - sum(deductions, Self.companyStockWords)
    }
    public var taxTotal: Decimal { taxes.reduce(0) { $0 + $1.current } }
    /// What they earned: every earning but the company's stock contribution.
    public var grossPay: Decimal { earnings.reduce(0) { $0 + $1.current } - companyStock }

    /// A stub with a bonus on it, which isn't copied to other paydays.
    public var hasBonus: Bool { bonus > regular / 20 }

    static let bonusWords = ["INCENTIVE", "BONUS"]
    static let companyStockWords = ["STK CONT", "STOCK CONT"]
    static let retirementWords = ["401K", "401(K)"]
    static let stockPurchaseWords = ["STOCK PURCH", "STK PURCH"]
}

extension Paystub {
    /// Reads a stub from its text (PDFKit's, columns interleaved). Money lines
    /// are a label, perhaps hours and a rate, then this period's amount and
    /// the year to date; a line under EARNINGS, TAX or DEDUCTIONS belongs to
    /// that section. Refused unless earnings less taxes and deductions come to
    /// the net pay.
    public static func parse(_ text: String) throws -> Paystub {
        let money = /^(?<label>.+?)\s+(?:[\d.,]+\s+){0,2}(?<current>-?\$[\d,]+\.\d\d)\s+(?<ytd>-?\$[\d,]+\.\d\d)$/
        let period = /Pay Period:\s*(?<start>\d{1,2}\/\d{1,2}\/\d{4})\s*-\s*(?<end>\d{1,2}\/\d{1,2}\/\d{4})/
        let deposit = /Deposit Date:\s*(?<day>\d{1,2}\/\d{1,2}\/\d{4})/

        enum Section { case none, earnings, taxes, deductions }
        var section = Section.none
        var earnings: [PaystubLine] = [], taxes: [PaystubLine] = [], deductions: [PaystubLine] = []
        var totals: [Section: Decimal] = [:]
        var net: (Decimal, Decimal)?
        var start: Day?, end: Day?, depositDate: Day?

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let found = line.firstMatch(of: period) {
                start = day(String(found.start)); end = day(String(found.end))
                continue
            }
            if let found = line.firstMatch(of: deposit) { depositDate = day(String(found.day)); continue }
            // Headers end with their columns ("TAX CURRENT YEAR TO DATE"), unlike
            // "Tax Method Single" in the withholding column beside deductions.
            let upper = line.uppercased()
            if upper.hasSuffix("CURRENT YEAR TO DATE") {
                if upper.hasPrefix("EARNINGS ") { section = .earnings }
                if upper.hasPrefix("TAX ") { section = .taxes }
                if upper.hasPrefix("DEDUCTIONS ") { section = .deductions }
                continue
            }
            guard let found = line.wholeMatch(of: money),
                let current = amount(String(found.current)), let ytd = amount(String(found.ytd))
            else { continue }
            var label = String(found.label).trimmingCharacters(in: .whitespaces)
            let preTax = label.hasSuffix("*")
            if preTax { label = String(label.dropLast()).trimmingCharacters(in: .whitespaces) }
            if label.caseInsensitiveCompare("Net Pay") == .orderedSame { net = (current, ytd); continue }
            if label.caseInsensitiveCompare("Total") == .orderedSame { totals[section] = current; continue }
            let entry = PaystubLine(name: label, current: current, yearToDate: ytd, preTax: preTax)
            switch section {
            case .earnings: earnings.append(entry)
            case .taxes: taxes.append(entry)
            case .deductions: deductions.append(entry)
            case .none: continue
            }
        }

        guard let start, let end, let depositDate, let net, !earnings.isEmpty else { throw PaystubProblem.notAStub }
        let stub = Paystub(
            periodStart: start, periodEnd: end, depositDate: depositDate, earnings: earnings,
            taxes: taxes, deductions: deductions, netPay: net.0, netPayYearToDate: net.1)
        let sums: [Section: Decimal] = [
            .earnings: earnings.reduce(0) { $0 + $1.current },
            .taxes: stub.taxTotal, .deductions: deductions.reduce(0) { $0 + $1.current }
        ]
        let printedTotalsAgree = totals.allSatisfy { section, total in sums[section] == total }
        guard printedTotalsAgree, sums[.earnings]! - sums[.taxes]! - sums[.deductions]! == net.0 else {
            throw PaystubProblem.doesntAddUp
        }
        return stub
    }

    private static func amount(_ text: String) -> Decimal? {
        Decimal(string: text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ""))
    }

    /// MM/DD/YYYY.
    private static func day(_ text: String) -> Day? {
        let parts = text.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Day(year: parts[2], month: parts[0], day: parts[1])
    }
}

/// A bonus or a stock vest they expect, kept apart from the monthly budget.
public struct ExpectedPay: Hashable, Identifiable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case bonus, vest }

    public var id: UUID
    public var kind: Kind
    public var title: String
    /// Nil while the date isn't known (a grant's vesting schedule).
    public var day: Day?
    /// Just the month, when that's all they know ("a bonus in March"); nil with a day.
    public var month: Month?
    public var gross: Decimal
    public var note: String
    /// The amount is a guess (a bonus before it's announced).
    public var estimate: Bool

    public init(
        id: UUID = UUID(), kind: Kind, title: String, day: Day? = nil, month: Month? = nil, gross: Decimal,
        note: String = "", estimate: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.day = day
        self.month = day == nil ? month : nil
        self.gross = gross
        self.note = note
        self.estimate = estimate
    }

    /// Items saved before months and estimates read back with neither.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        day = try container.decodeIfPresent(Day.self, forKey: .day)
        month = try container.decodeIfPresent(Month.self, forKey: .month)
        gross = try container.decode(Decimal.self, forKey: .gross)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        estimate = try container.decodeIfPresent(Bool.self, forKey: .estimate) ?? false
    }
}

/// How they've paid, set once and changed when something does (a raise):
/// salary, how often and one known payday, the 401(k) and its match, the
/// stock plan, and the accounts they land in. Each paycheck's figures are
/// worked out from these; synced deposits say what actually arrived.
public struct PayProfile: Hashable, Codable, Sendable {
    /// Base pay a year, before anything is taken out. 0 until they set it.
    public var annualSalary: Decimal = 0
    /// Days between paydays (14: every other week).
    public var everyDays = 14
    /// Any one payday, the others counted from it.
    public var knownPayday: Day?
    /// Percents of pay.
    public var retirementPercent: Decimal = 6
    public var retirementPreTax = true
    /// The employer matches this percent of what they put in…
    public var matchPercent: Decimal = 100
    /// …on up to this percent of pay.
    public var matchUpToPercent: Decimal = 6
    public var stockPerCheck: Decimal = 70
    /// What the company adds to their stock purchase each check.
    public var stockCompanyPerCheck: Decimal = 10.50
    public var retirementAccountID: UUID?
    public var stockAccountID: UUID?
    /// The income category their paychecks are filed under.
    public var incomeCategory = "Paychecks"
    public var planIncomeFromPay = true
    public var expected: [ExpectedPay] = []

    public init() {}

    /// Salary and a payday are set, so each paycheck can be worked out.
    public var isSet: Bool { annualSalary > 0 && knownPayday != nil && everyDays > 0 }

    /// With the 401(k) and stock plan guessed from account names, for a
    /// profile they haven't saved yet: a retirement account named 401, one named
    /// ASPP or ESPP.
    public func guessingAccounts(_ accounts: [Account]) -> PayProfile {
        var profile = self
        let open = accounts.filter { $0.archivedOn == nil }
        if profile.retirementAccountID == nil {
            profile.retirementAccountID = open.first { $0.accountClass == .retirement && $0.name.localizedCaseInsensitiveContains("401") }?.id
        }
        if profile.stockAccountID == nil {
            profile.stockAccountID =
                open.first { account in
                    ["ASPP", "ESPP", "Stock Purchase"].contains { account.name.localizedCaseInsensitiveContains($0) }
                }?.id
        }
        return profile
    }

    /// With what a stub shows filled in: its regular pay over a year, its
    /// deposit date as the known payday, the 401(k) percent and the stock
    /// purchase with the company's part. An optional shortcut, never needed.
    public func filled(from stub: Paystub) -> PayProfile {
        var profile = self
        guard stub.regular > 0 else { return profile }
        profile.annualSalary = stub.regular * Decimal(Pay.paydaysPerYear(self))
        profile.knownPayday = stub.depositDate
        if stub.retirement > 0 { profile.retirementPercent = Pay.cents(stub.retirement / stub.regular * 100) }
        if stub.stockPurchase > 0 {
            profile.stockPerCheck = stub.stockPurchase
            profile.stockCompanyPerCheck = stub.companyStock
        }
        return profile
    }

    /// Profiles saved before a field existed read back with its default; the
    /// stub-based version's company percent becomes an amount a check.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let old = try decoder.container(keyedBy: OldKeys.self)
        let defaults = PayProfile()
        annualSalary = try container.decodeIfPresent(Decimal.self, forKey: .annualSalary) ?? 0
        everyDays = try container.decodeIfPresent(Int.self, forKey: .everyDays) ?? defaults.everyDays
        knownPayday = try container.decodeIfPresent(Day.self, forKey: .knownPayday)
        retirementPercent = try container.decodeIfPresent(Decimal.self, forKey: .retirementPercent) ?? defaults.retirementPercent
        retirementPreTax = try container.decodeIfPresent(Bool.self, forKey: .retirementPreTax) ?? true
        matchPercent = try container.decodeIfPresent(Decimal.self, forKey: .matchPercent) ?? defaults.matchPercent
        matchUpToPercent = try container.decodeIfPresent(Decimal.self, forKey: .matchUpToPercent) ?? defaults.matchUpToPercent
        stockPerCheck = try container.decodeIfPresent(Decimal.self, forKey: .stockPerCheck) ?? defaults.stockPerCheck
        if let amount = try container.decodeIfPresent(Decimal.self, forKey: .stockCompanyPerCheck) {
            stockCompanyPerCheck = amount
        } else if let percent = try old.decodeIfPresent(Decimal.self, forKey: .stockCompanyPercent) {
            stockCompanyPerCheck = Pay.cents(stockPerCheck * percent / 100)
        }
        retirementAccountID = try container.decodeIfPresent(UUID.self, forKey: .retirementAccountID)
        stockAccountID = try container.decodeIfPresent(UUID.self, forKey: .stockAccountID)
        incomeCategory = try container.decodeIfPresent(String.self, forKey: .incomeCategory) ?? defaults.incomeCategory
        planIncomeFromPay = try container.decodeIfPresent(Bool.self, forKey: .planIncomeFromPay) ?? defaults.planIncomeFromPay
        expected = try container.decodeIfPresent([ExpectedPay].self, forKey: .expected) ?? []
    }

    private enum OldKeys: String, CodingKey { case stockCompanyPercent }
}

/// One paycheck as the settings work it out.
public struct ExpectedCheck: Hashable, Sendable {
    public var regular: Decimal
    /// Their 401(k), and the employer's match on it.
    public var retirement: Decimal
    public var match: Decimal
    public var stockPurchase: Decimal
    public var companyStock: Decimal

    public var retirementTotal: Decimal { retirement + match }
    public var stockTotal: Decimal { stockPurchase + companyStock }
}

/// A paycheck that arrived: synced deposits filed as paychecks near a payday,
/// added up over the accounts it was split into.
public struct PaycheckDeposit: Hashable, Sendable {
    /// The payday it's for, or the day it arrived when no payday is set.
    public var payday: Day
    /// When it arrived (the earliest, when split).
    public var day: Day
    public var net: Decimal
}

/// Payroll's money into an account over a month: theirs and their employer's.
public struct PayrollMoney: Hashable, Sendable {
    public var employee: Decimal
    public var employer: Decimal
    /// Some of it is the settings' expected amount: no transaction arrived for it.
    public var estimated: Bool

    public init(employee: Decimal, employer: Decimal, estimated: Bool) {
        self.employee = employee
        self.employer = employer
        self.estimated = estimated
    }

    public var total: Decimal { employee + employer }
}

/// Payroll deposits into their 401(k) and stock plan, for `Contributions`.
public struct Payroll: Hashable, Sendable {
    public struct Deposit: Hashable, Sendable {
        public var day: Day
        public var money: PayrollMoney
    }

    public var deposits: [UUID: [Deposit]] = [:]
    /// Each account's paydays that can't be told; a month with one falls back to transactions.
    public var unknown: [UUID: Set<Day>] = [:]
    /// The accounts pay goes into, from their first balance: a month with no
    /// payday since is nothing in, not unknown.
    public var accounts: Set<UUID> = []

    public init() {}

    /// Payroll's money into `account` over `days`, or nil when it has none
    /// there or a payday in them can't be told.
    public func money(into account: UUID, over days: ClosedRange<Day>) -> PayrollMoney? {
        guard accounts.contains(account), !(unknown[account] ?? []).contains(where: days.contains) else { return nil }
        let inside = (deposits[account] ?? []).filter { days.contains($0.day) }
        return PayrollMoney(
            employee: inside.reduce(0) { $0 + $1.money.employee },
            employer: inside.reduce(0) { $0 + $1.money.employer },
            estimated: inside.contains { $0.money.estimated })
    }
}

public enum Pay {
    /// How far a deposit can land from its payday: banks post pay a day or
    /// two early.
    static let depositReach = 3
    /// A plan's buys for a paycheck fall from a few days before its payday to
    /// five after, short of the next payday's (paid weekly, three after).
    static let buysBefore = 3
    static func buysAfter(_ profile: PayProfile) -> Int { min(5, profile.everyDays - buysBefore - 1) }

    public static func paydaysPerYear(_ profile: PayProfile) -> Int {
        profile.everyDays > 0 ? Int((365.0 / Double(profile.everyDays)).rounded()) : 0
    }

    /// One paycheck from the settings: the salary over the year's paydays,
    /// rounded to cents, then each part rounded. The match is its percent of
    /// what they put in, on up to its share of pay.
    public static func expected(_ profile: PayProfile) -> ExpectedCheck? {
        guard profile.isSet else { return nil }
        let regular = cents(profile.annualSalary / Decimal(paydaysPerYear(profile)))
        let retirement = cents(regular * profile.retirementPercent / 100)
        let match = cents(min(retirement, regular * profile.matchUpToPercent / 100) * profile.matchPercent / 100)
        return ExpectedCheck(
            regular: regular, retirement: retirement, match: match,
            stockPurchase: profile.stockPerCheck, companyStock: profile.stockCompanyPerCheck)
    }

    /// Paydays in `month`, every `everyDays` from the known one.
    public static func paydays(in month: Month, profile: PayProfile) -> [Day] {
        paydays(from: month.firstDay, through: month.lastDay, profile: profile)
    }

    static func paydays(from first: Day, through last: Day, profile: PayProfile) -> [Day] {
        guard let anchor = profile.knownPayday, profile.everyDays > 0, first <= last else { return [] }
        let offset = ((first.ordinal - anchor.ordinal) % profile.everyDays + profile.everyDays) % profile.everyDays
        let start = offset == 0 ? first.ordinal : first.ordinal + profile.everyDays - offset
        return stride(from: start, through: last.ordinal, by: profile.everyDays).map(Day.init(ordinal:))
    }

    public static func threePaycheckMonths(from month: Month, months: Int, profile: PayProfile) -> [Month] {
        (0..<months).map { month.adding($0) }.filter { paydays(in: $0, profile: profile).count >= 3 }
    }

    /// Paydays after `today` through the end of the month `months` from now.
    public static func upcomingPaydays(_ profile: PayProfile, after today: Day, months: Int) -> [Day] {
        paydays(from: today.adding(1), through: Month(today).adding(months).lastDay, profile: profile)
    }

    /// The paychecks that arrived: money in filed under their paycheck category,
    /// within a few days of a payday, added up per payday. Without a known
    /// payday, each day's deposits are one paycheck.
    public static func paychecks(in transactions: [Transaction], profile: PayProfile) -> [PaycheckDeposit] {
        var found: [Day: PaycheckDeposit] = [:]
        for transaction in transactions where transaction.amount > 0 && transaction.category == profile.incomeCategory {
            let payday: Day
            if profile.knownPayday != nil {
                let near = paydays(from: transaction.day.adding(-depositReach), through: transaction.day.adding(depositReach), profile: profile)
                guard let nearest = near.min(by: { abs($0.ordinal - transaction.day.ordinal) < abs($1.ordinal - transaction.day.ordinal) })
                else { continue }
                payday = nearest
            } else {
                payday = transaction.day
            }
            var check = found[payday] ?? PaycheckDeposit(payday: payday, day: transaction.day, net: 0)
            check.net += transaction.amount
            check.day = min(check.day, transaction.day)
            found[payday] = check
        }
        return found.values.sorted { $0.payday < $1.payday }
    }

    /// The latest paycheck, passing over one half again the size of the one
    /// before it (a bonus paid with it).
    public static func latestNet(_ paychecks: [PaycheckDeposit], through day: Day? = nil) -> PaycheckDeposit? {
        let shown = paychecks.filter { check in day.map { check.payday <= $0 } ?? true }.sorted { $0.payday < $1.payday }
        for (index, check) in shown.enumerated().reversed() {
            guard index > 0 else { return check }
            if check.net <= shown[index - 1].net * 3 / 2 { return check }
        }
        return nil
    }

    /// Take-home a month on average: a paycheck's net over a year, over twelve.
    public static func monthlyTakeHome(net: Decimal, profile: PayProfile) -> Decimal {
        cents(net * Decimal(paydaysPerYear(profile)) / 12)
    }

    /// The budget plans the paychecks every month has (two paid every other
    /// week, four weekly) at the latest net deposited by the month's end; an
    /// extra payday, bonuses and the stock plan stay out. A month before any
    /// paycheck keeps what they typed.
    public static func plannedPaychecks(_ profile: PayProfile) -> Int { paydaysPerYear(profile) / 12 }

    public static func planned(_ plan: BudgetPlan, month: Month, profile: PayProfile, paychecks: [PaycheckDeposit]) -> BudgetPlan {
        guard plansIncome(month: month, profile: profile, paychecks: paychecks),
            let latest = latestNet(paychecks, through: month.lastDay)
        else { return plan }
        var planned = plan
        planned.plannedIncome[profile.incomeCategory] = latest.net * Decimal(plannedPaychecks(profile))
        return planned
    }

    /// Whether `planned` plans the month's paychecks from pay rather than what they typed.
    public static func plansIncome(month: Month, profile: PayProfile, paychecks: [PaycheckDeposit]) -> Bool {
        profile.planIncomeFromPay && latestNet(paychecks, through: month.lastDay) != nil
    }

    /// How `planned` planned the month's paychecks, for the budget line.
    public static func incomeNote(month: Month, profile: PayProfile, paychecks: [PaycheckDeposit]) -> String {
        let net = latestNet(paychecks, through: month.lastDay)?.net ?? 0
        let planned = plannedPaychecks(profile)
        let note = "\(planned) paychecks of \(net.formatted(.currency(code: "USD"))), from your latest deposit."
        let count = paydays(in: month, profile: profile).count
        guard count > planned else { return note }
        let name = month.firstDay.startDate(in: .gmt).formatted(Date.FormatStyle(timeZone: .gmt).month(.wide))
        let extra = planned == 2 ? "the third stays" : count - planned == 1 ? "the extra one stays" : "the extra ones stay"
        return note + " \(name) has \(count) paydays; \(extra) out of the budget."
    }

    /// Bonuses and vests still to come (or not yet dated), soonest first.
    public static func upcoming(_ profile: PayProfile, today: Day) -> [ExpectedPay] {
        // A month-only item sorts by its first day, and lasts the month.
        func soonest(_ item: ExpectedPay) -> Int { item.day?.ordinal ?? item.month?.firstDay.ordinal ?? .max }
        return profile.expected.filter { item in
            if let day = item.day { return day >= today }
            return item.month.map { $0 >= Month(today) } ?? true
        }
        .sorted { (soonest($0), $0.title) < (soonest($1), $1.title) }
    }

    /// Each payday's money into their 401(k) (theirs and the match) and stock
    /// plan (their purchase and the company's part) over `months`, from the
    /// account's first balance on: what it bought for that paycheck, split as
    /// the settings split it, or, when a paycheck arrived and the account
    /// shows no buys for it, the settings' amount, marked estimated. A payday
    /// with neither can't be told.
    public static func payroll(
        profile: PayProfile, transactions: [Transaction], firstBalances: [UUID: Day],
        kinds: [String: CategoryKind], months: ClosedRange<Month>, today: Day
    ) -> Payroll {
        var payroll = Payroll()
        guard let check = expected(profile) else { return payroll }
        let landed = Set(paychecks(in: transactions, profile: profile).map(\.payday))
        let paired = Set(TransferMatch.pairs(in: transactions, kinds: kinds).flatMap { [$0.outgoing, $0.incoming] })
        let byAccount = Dictionary(grouping: transactions, by: \.accountID)
        let plans = [
            (profile.retirementAccountID, check.retirement, check.match),
            (profile.stockAccountID, check.stockPurchase, check.companyStock)
        ]
        // From the payday whose buys can still land in the first month.
        let days = paydays(
            from: months.lowerBound.firstDay.adding(-buysAfter(profile)), through: min(months.upperBound.lastDay, today),
            profile: profile)
        for case let (id?, employee, employer) in plans {
            guard let first = firstBalances[id] else { continue }
            payroll.accounts.insert(id)
            let mine = byAccount[id] ?? []
            // A payday just before the first balance still has its buys after it.
            for payday in days where payday.adding(buysAfter(profile)) >= first {
                let window = max(payday.adding(-buysBefore), first)...payday.adding(buysAfter(profile))
                let bought = mine.filter { window.contains($0.day) }
                    .reduce(Decimal(0)) { $0 + Contributions.bought($1, paired: paired.contains($1.id), kinds: kinds) }
                let money: PayrollMoney
                if bought > 0 {
                    let their = employee + employer > 0 ? cents(bought * employee / (employee + employer)) : bought
                    money = PayrollMoney(employee: their, employer: bought - their, estimated: false)
                } else if payday < first {
                    continue
                } else if landed.contains(payday) {
                    money = PayrollMoney(employee: employee, employer: employer, estimated: true)
                } else {
                    payroll.unknown[id, default: []].insert(payday)
                    continue
                }
                payroll.deposits[id, default: []].append(.init(day: max(payday, first), money: money))
            }
        }
        return payroll
    }

    static func cents(_ value: Decimal) -> Decimal {
        var value = value, rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return rounded
    }
}

/// How much of what they earned they kept: what they moved into savings and
/// investing plus payroll's 401(k), match and stock, over salary plus the
/// match. Beside it, the share of take-home they moved into savings.
public struct SavingsRate: Hashable, Sendable {
    public var saved: Decimal
    public var earned: Decimal
    public var moved: Decimal
    public var takeHome: Decimal

    public init(saved: Decimal, earned: Decimal, moved: Decimal, takeHome: Decimal) {
        self.saved = saved
        self.earned = earned
        self.moved = moved
        self.takeHome = takeHome
    }

    /// A month from the settings: each payday through today adds a
    /// paycheck's 401(k), match and stock to what the budget's savings moved
    /// (`moved`), and its salary and match to what they earned. Take-home is
    /// what arrived for those paydays. Nil until the settings are set.
    public static func month(
        _ month: Month, profile: PayProfile, paychecks: [PaycheckDeposit],
        moved: Decimal, today: Day
    ) -> SavingsRate? {
        guard let check = Pay.expected(profile) else { return nil }
        let count = Decimal(Pay.paydays(in: month, profile: profile).filter { $0 <= today }.count)
        let arrived = paychecks.filter { Month($0.payday) == month && $0.payday <= today }.reduce(Decimal(0)) { $0 + $1.net }
        return SavingsRate(
            saved: moved + count * (check.retirementTotal + check.stockTotal),
            earned: count * (check.regular + check.match), moved: moved, takeHome: arrived)
    }

    /// Where saving goes: investing accounts, and cash accounts they don't
    /// spend from (an emergency fund, even one part of a paycheck lands in),
    /// but not the ones pay goes straight into, which payroll counts already.
    /// Spending from an account is a few charges, filed or not, that aren't
    /// transfers: one bank fee doesn't make savings an everyday account.
    public static func savingAccounts(
        _ accounts: [Account], transactions: [Transaction], kinds: [String: CategoryKind],
        profile: PayProfile
    ) -> Set<UUID> {
        let payroll = payrollAccounts(profile)
        let paired = Set(TransferMatch.pairs(in: transactions, kinds: kinds).flatMap { [$0.outgoing, $0.incoming] })
        var charges: [UUID: Int] = [:]
        for transaction in transactions
        where transaction.amount < 0 && !paired.contains(transaction.id)
            && Spending.spendingCategory(of: transaction, kinds: kinds) != nil
        {
            charges[transaction.accountID, default: 0] += 1
        }
        let everyday = Set(charges.filter { $0.value >= everydayCharges }.keys)
        return Set(
            accounts.filter { account in
                switch account.accountClass {
                case .taxable, .retirement, .equity: true
                case .cash: !everyday.contains(account.id)
                case .otherAssets, .debt: false
                }
            }.map(\.id)
        ).subtracting(payroll)
    }

    /// A cash account with this many charges is one they spend from.
    static let everydayCharges = 3

    static func payrollAccounts(_ profile: PayProfile) -> Set<UUID> {
        Set([profile.retirementAccountID, profile.stockAccountID].compactMap { $0 })
    }

    /// Money moved from their other accounts into `saving` ones, by month:
    /// matched transfers, contributions from accounts Compass can't see
    /// ("CASH CONTRIBUTION"), and pay deposited straight into one, less what
    /// went back out of that account to a non-saving one the same month
    /// (each account's month is never below zero). A move between saving
    /// accounts, or out of one pay goes into (counted by payroll already),
    /// isn't new saving. What went out to cover spending a goal paid for
    /// (`settling`) isn't taken back out.
    public static func moved(
        _ transactions: [Transaction], kinds: [String: CategoryKind], into saving: Set<UUID>,
        profile: PayProfile, settling: [UUID: Decimal] = [:]
    ) -> [Month: Decimal] {
        let byID = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pairs = TransferMatch.pairs(in: transactions, kinds: kinds)
        let paired = Set(pairs.flatMap { [$0.outgoing, $0.incoming] })
        let notNew = saving.union(payrollAccounts(profile))
        struct Key: Hashable { var account: UUID; var month: Month }
        var net: [Key: Decimal] = [:]
        for transaction in transactions where transaction.amount > 0 && saving.contains(transaction.accountID) && !paired.contains(transaction.id) {
            let pay = transaction.category == profile.incomeCategory
            let fromElsewhere =
                Contributions.role(of: transaction, paired: false, kinds: kinds) == .contribution
                && !Contributions.isPayroll(transaction)
            if pay || fromElsewhere { net[Key(account: transaction.accountID, month: Month(transaction.day)), default: 0] += transaction.amount }
        }
        for pair in pairs {
            guard let out = byID[pair.outgoing], let into = byID[pair.incoming] else { continue }
            if !notNew.contains(out.accountID), saving.contains(into.accountID) {
                net[Key(account: into.accountID, month: Month(into.day)), default: 0] += into.amount
            } else if saving.contains(out.accountID), !notNew.contains(into.accountID) {
                // Taken back out to checking (or a card): not saved after all.
                net[Key(account: out.accountID, month: Month(out.day)), default: 0] += out.amount + (settling[out.id] ?? 0)
            }
        }
        var moved: [Month: Decimal] = [:]
        for (key, amount) in net { moved[key.month, default: 0] += max(amount, 0) }
        return moved
    }

    public static func total(_ rates: [SavingsRate]) -> SavingsRate {
        rates.reduce(SavingsRate(saved: 0, earned: 0, moved: 0, takeHome: 0)) {
            SavingsRate(
                saved: $0.saved + $1.saved, earned: $0.earned + $1.earned,
                moved: $0.moved + $1.moved, takeHome: $0.takeHome + $1.takeHome)
        }
    }

    public var ofGross: Decimal? { earned > 0 ? saved / earned : nil }
    public var ofTakeHome: Decimal? { takeHome > 0 ? moved / takeHome : nil }
}

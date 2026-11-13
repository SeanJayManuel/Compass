import Core
import Foundation
import Testing

/// A made-up stub in the layout of one payroll provider's Statement of Earnings and
/// Deductions, as PDFKit reads it: columns interleaved, every money line a
/// label with this period's amount and the year to date.
let sampleStubText = """
    Statement of Earnings and Deductions.
    Acme Associates, Inc., 1 Example Way Springfield, ST 00000. Tel:000-000-0000
    Paid To:
    A SAMPLE
    1 MAIN ST. APT.1 ANYTOWN, CA 90000
    Pay Period: 10/03/2026 - 10/16/2026
    Deposit Date: 10/22/2026
    Advice #: 123456789
    Win: *****1234
    EARNINGS HOURS RATE CURRENT YEAR TO DATE
    PAY DISTRIBUTION
    REGULAR EARNING $3,000.00 $60,000.00
    CHECK DEPOSIT
    CO STK CONT $7.50 $150.00
    Some Bank National Association
    MGMT INCENTIVE $0.00 $9,000.00
    xxxxxxx1234 $2,039.50
    Total $3,007.50 $69,150.00
    TAX CURRENT YEAR TO DATE
    CATEGORY
    FEDERAL TAX $300.00 $6,000.00
    Pay Category Salaried
    CALIFORNIA $120.00 $2,400.00
    SDI $33.00 $660.00
    TIME OFF AMOUNT
    SOCIAL SECURITY $186.00 $3,720.00
    PLAN FLEXTO
    MEDICARE $43.50 $870.00
    USED YTD 8.00
    Total $682.50 $13,650.00
    FEDERAL TAX WITHHOLDING
    DEDUCTIONS CURRENT YEAR TO DATE
    Tax Method Single
    INS MED U * $40.00 $800.00
    Claim Dependents $0.00
    INS DEN U * $5.00 $100.00
    Additional Withholding $0.00
    CRITICAL ILL * $2.00 $40.00
    STATE TAX WITHHOLDING
    401K * $180.00 $3,600.00
    Tax Method Single
    ACCIDENT * $1.00 $20.00
    Exemptions 0
    CO STK CONT $7.50 $150.00
    Additional Withholding $0.00
    STOCK PURCH $50.00 $1,000.00
    Total $285.50 $5,710.00
    All Material Wal-Mart Associates, Inc.
    Confidential.©2026
    CURRENT YEAR TO DATE
    Net Pay $2,039.50 $49,790.00
    """

func day(_ year: Int, _ month: Int, _ day: Int) -> Day { Day(year: year, month: month, day: day) }

@Suite struct PaystubTests {
    @Test func aStubReadsItsDatesAndEveryLine() throws {
        let stub = try Paystub.parse(sampleStubText)
        #expect(stub.periodStart == day(2026, 10, 3))
        #expect(stub.periodEnd == day(2026, 10, 16))
        #expect(stub.depositDate == day(2026, 10, 22))
        #expect(stub.earnings.map(\.name) == ["REGULAR EARNING", "CO STK CONT", "MGMT INCENTIVE"])
        #expect(stub.taxes.map(\.name) == ["FEDERAL TAX", "CALIFORNIA", "SDI", "SOCIAL SECURITY", "MEDICARE"])
        #expect(stub.deductions.map(\.name) == ["INS MED U", "INS DEN U", "CRITICAL ILL", "401K", "ACCIDENT", "CO STK CONT", "STOCK PURCH"])
        #expect(stub.deductions.first { $0.name == "401K" } == PaystubLine(name: "401K", current: 180, yearToDate: 3_600, preTax: true))
        #expect(stub.netPay == 2_039.50)
        #expect(stub.netPayYearToDate == 49_790)
    }

    @Test func aStubNamesWhatEachLineIs() throws {
        let stub = try Paystub.parse(sampleStubText)
        #expect(stub.regular == 3_000)
        #expect(stub.bonus == 0)
        #expect(stub.bonusYearToDate == 9_000)
        #expect(stub.companyStock == 7.50)
        #expect(stub.retirement == 180)
        #expect(stub.stockPurchase == 50)
        #expect(stub.benefits == 48)
        #expect(stub.taxTotal == 682.50)
        // Gross pay is what they earned; the company's stock contribution is shown as earnings but isn't pay.
        #expect(stub.grossPay == 3_000)
    }

    @Test func aStubThatDoesntAddUpIsRefused() {
        let wrong = sampleStubText.replacingOccurrences(of: "Net Pay $2,039.50", with: "Net Pay $2,139.50")
        #expect(throws: PaystubProblem.doesntAddUp) { try Paystub.parse(wrong) }
        #expect(throws: PaystubProblem.notAStub) { try Paystub.parse("A grocery receipt\nTotal $12.00") }
    }

    @Test func hoursAndARateBeforeTheAmountsAreRead() throws {
        let hourly = sampleStubText.replacingOccurrences(of: "REGULAR EARNING $3,000.00", with: "REGULAR EARNING 80.00 37.50 $3,000.00")
        #expect(try Paystub.parse(hourly).regular == 3_000)
    }
}

/// Their pay as they set it once a year (round 3: "I will NOT import paystubs
/// every paycheck"). Made-up figures: $78,000 a year, paid every other
/// Thursday from Oct 22, 2026.
let payProfile: PayProfile = {
    var profile = PayProfile()
    profile.annualSalary = 78_000
    profile.knownPayday = day(2026, 10, 22)
    profile.stockPerCheck = 50
    profile.stockCompanyPerCheck = 7.50
    return profile
}()

func paycheck(_ day: Day, _ amount: Decimal, account: UUID = UUID(), category: String = "Paychecks") -> Transaction {
    Transaction(
        accountID: account, day: day, amount: amount, merchant: "Payroll", category: category,
        externalID: "pay-\(day.ordinal)-\(amount)")
}

@Suite struct PayScheduleTests {
    let profile = payProfile

    @Test func eachCheckIsTheSalaryOverItsPaydaysWithTheMatchUpToSixPercent() throws {
        let check = try #require(Pay.expected(profile))
        #expect(check.regular == 3_000)
        #expect(check.retirement == 180 && check.match == 180 && check.retirementTotal == 360)
        #expect(check.stockPurchase == 50 && check.companyStock == 7.50)
        // Putting in 8% still gets 6% matched.
        var more = profile
        more.retirementPercent = 8
        #expect(Pay.expected(more)?.retirement == 240 && Pay.expected(more)?.match == 180)
        // Not set up yet: nothing is expected.
        #expect(Pay.expected(PayProfile()) == nil)
    }

    /// The check is rounded to cents, then each part: 184.52 + 184.52, not 12% of the check (369.05).
    @Test func eachPartIsRoundedToCents() {
        var profile = profile
        profile.annualSalary = Decimal(string: "79959.88")!
        let check = Pay.expected(profile)
        #expect(check?.regular == Decimal(string: "3075.38")!)
        #expect(check?.retirementTotal == Decimal(string: "369.04")!)
    }

    @Test func paydaysRunEveryTwoWeeksFromTheKnownOne() {
        #expect(Pay.paydays(in: Month(year: 2026, month: 11), profile: profile) == [day(2026, 11, 5), day(2026, 11, 19)])
        #expect(Pay.paydays(in: Month(year: 2026, month: 9), profile: profile) == [day(2026, 9, 10), day(2026, 9, 24)])
        #expect(
            Pay.threePaycheckMonths(from: Month(year: 2026, month: 11), months: 14, profile: profile)
                == [Month(year: 2026, month: 12), Month(year: 2027, month: 7), Month(year: 2027, month: 12)])
        // The next six months' paydays, after today.
        let upcoming = Pay.upcomingPaydays(profile, after: day(2026, 10, 31), months: 6)
        #expect(upcoming.first == day(2026, 11, 5) && upcoming.last == day(2027, 4, 22) && upcoming.count == 13)
        #expect(Pay.paydays(in: Month(year: 2026, month: 11), profile: PayProfile()).isEmpty)
    }

    /// Paychecks come from synced deposits filed as Paychecks near a payday;
    /// one split over two accounts is one paycheck.
    @Test func paychecksAreDepositsNearAPayday() {
        let transactions = [
            paycheck(day(2026, 10, 6), 1_950),
            paycheck(day(2026, 10, 20), 2_000), paycheck(day(2026, 10, 20), 39.50),
            // A bonus paid on its own day, money out filed as pay, and other income aren't paychecks.
            paycheck(day(2026, 10, 27), 6_000), paycheck(day(2026, 10, 21), -20),
            paycheck(day(2026, 10, 20), 3.10, category: "Interest")
        ]
        let found = Pay.paychecks(in: transactions, profile: profile)
        #expect(found.map(\.payday) == [day(2026, 10, 8), day(2026, 10, 22)])
        #expect(found.map(\.net) == [1_950, 2_039.50])
        #expect(Pay.latestNet(found)?.net == 2_039.50)
        #expect(Pay.monthlyTakeHome(net: 2_039.50, profile: profile) == Decimal(string: "4418.92")!)
    }

    /// A bonus paid with a paycheck doesn't become the paycheck to plan from.
    @Test func aPaycheckWithABonusIsntTheLatestNet() {
        let found = Pay.paychecks(in: [paycheck(day(2026, 10, 20), 2_039.50), paycheck(day(2026, 11, 3), 8_000)], profile: profile)
        #expect(found.count == 2)
        #expect(Pay.latestNet(found)?.net == 2_039.50)
    }

    /// The budget plans two paychecks a month; a third payday stays out (round 3).
    @Test func theBudgetPlansTwoPaychecksAMonth() {
        let found = Pay.paychecks(in: [paycheck(day(2026, 10, 6), 1_950), paycheck(day(2026, 10, 20), 2_039.50)], profile: profile)
        let typed = BudgetPlan(flexibleBudget: 1_000, plannedIncome: ["Paychecks": 5_000, "Interest": 5])
        let december = Pay.planned(typed, month: Month(year: 2026, month: 12), profile: profile, paychecks: found)
        #expect(december.plannedIncome == ["Paychecks": 4_079, "Interest": 5])
        #expect(
            Pay.incomeNote(month: Month(year: 2026, month: 12), profile: profile, paychecks: found)
                == "2 paychecks of $2,039.50, from your latest deposit. December has 3 paydays; the third stays out of the budget.")
        #expect(
            Pay.incomeNote(month: Month(year: 2026, month: 11), profile: profile, paychecks: found)
                == "2 paychecks of $2,039.50, from your latest deposit.")
        #expect(Pay.plansIncome(month: Month(year: 2026, month: 12), profile: profile, paychecks: found))
        // A month before any paycheck keeps what they typed.
        #expect(Pay.planned(typed, month: Month(year: 2026, month: 9), profile: profile, paychecks: found) == typed)
        #expect(!Pay.plansIncome(month: Month(year: 2026, month: 9), profile: profile, paychecks: found))
        var off = profile
        off.planIncomeFromPay = false
        #expect(Pay.planned(typed, month: Month(year: 2026, month: 12), profile: off, paychecks: found) == typed)
    }

    /// Paid weekly, the budget plans four paychecks a month, and the fifth payday stays out.
    @Test func weeklyPayPlansFourPaychecks() {
        var weekly = profile
        weekly.everyDays = 7
        let found = Pay.paychecks(in: [paycheck(day(2026, 10, 20), 1_000)], profile: weekly)
        let typed = BudgetPlan(flexibleBudget: 0, plannedIncome: ["Paychecks": 1])
        #expect(Pay.planned(typed, month: Month(year: 2026, month: 12), profile: weekly, paychecks: found).plannedIncome["Paychecks"] == 4_000)
        #expect(
            Pay.incomeNote(month: Month(year: 2026, month: 12), profile: weekly, paychecks: found)
                == "4 paychecks of $1,000.00, from your latest deposit. December has 5 paydays; the extra one stays out of the budget.")
    }

    /// An imported stub fills in the settings; nothing needs one.
    @Test func aStubFillsInTheSettings() throws {
        let filled = PayProfile().filled(from: try Paystub.parse(sampleStubText))
        #expect(filled.annualSalary == 78_000 && filled.knownPayday == day(2026, 10, 22))
        #expect(filled.retirementPercent == 6 && filled.stockPerCheck == 50 && filled.stockCompanyPerCheck == 7.50)
    }

    @Test func the401kAndStockPlanAreGuessedFromNamesUntilHePicks() {
        let plan = Account(name: "Acme 401(k) Plan", accountClass: .retirement, source: .simplefin)
        let stock = Account(name: "Acme ESPP", accountClass: .taxable, source: .simplefin)
        let roth = Account(name: "ROTH IRA", accountClass: .retirement, source: .simplefin)
        let guessed = PayProfile().guessingAccounts([roth, plan, stock])
        #expect(guessed.retirementAccountID == plan.id && guessed.stockAccountID == stock.id)
        var picked = PayProfile()
        picked.retirementAccountID = roth.id
        #expect(picked.guessingAccounts([roth, plan, stock]).retirementAccountID == roth.id)
    }

    @Test func upcomingBonusesAndVestsAreKeptApartFromTheBudget() {
        var profile = profile
        profile.expected = [
            ExpectedPay(kind: .bonus, title: "Annual bonus", day: day(2027, 3, 15), gross: 17_000),
            ExpectedPay(kind: .vest, title: "RSU grant", day: nil, gross: 25_000),
            ExpectedPay(kind: .bonus, title: "Last year's bonus", day: day(2026, 3, 13), gross: 15_000)
        ]
        #expect(Pay.upcoming(profile, today: day(2026, 10, 30)).map(\.title) == ["Annual bonus", "RSU grant"])
    }

    /// Profiles saved by the stub-based version read back, the company's
    /// stock percent becoming an amount a check.
    @Test func anOlderProfileReadsBack() throws {
        let old = #"{"everyDays":14,"retirementPercent":6,"stockPerCheck":70,"stockCompanyPercent":15}"#
        let profile = try JSONDecoder().decode(PayProfile.self, from: Data(old.utf8))
        #expect(profile.stockCompanyPerCheck == 10.50 && profile.annualSalary == 0 && profile.knownPayday == nil)
    }
}

@Suite struct PayrollContributionTests {
    let plan = Account(name: "401(k)", accountClass: .retirement, source: .simplefin)
    let espp = Account(name: "ESPP", accountClass: .taxable, source: .simplefin)
    let today = day(2026, 10, 31)
    let october = Month(year: 2026, month: 10)
    var profile: PayProfile {
        var profile = payProfile
        profile.retirementAccountID = plan.id
        profile.stockAccountID = espp.id
        return profile
    }
    var snapshots: [BalanceSnapshot] {
        [
            BalanceSnapshot(accountID: plan.id, day: day(2026, 9, 30), source: .simplefin, balance: 20_000),
            BalanceSnapshot(accountID: plan.id, day: day(2026, 10, 30), source: .simplefin, balance: 21_000),
            // The stock plan's balances start mid-month, after the first payday.
            BalanceSnapshot(accountID: espp.id, day: day(2026, 10, 15), source: .simplefin, balance: 1_000),
            BalanceSnapshot(accountID: espp.id, day: day(2026, 10, 30), source: .simplefin, balance: 1_200)
        ]
    }
    func report(_ transactions: [Transaction]) -> [AccountContributions] {
        let firstBalances = Dictionary(snapshots.map { ($0.accountID, $0.day) }, uniquingKeysWith: min)
        let payroll = Pay.payroll(
            profile: profile, transactions: transactions, firstBalances: firstBalances,
            kinds: [:], months: october...october, today: today)
        return Contributions.report(
            accounts: [plan, espp], snapshots: snapshots, transactions: transactions,
            kinds: [:], today: today, months: october...october, payroll: payroll)
    }

    func buy(_ day: Day, _ amount: Decimal, _ id: String) -> Transaction {
        Transaction(accountID: plan.id, day: day, amount: amount, merchant: "RUSSELL 2000", category: "Transfer", externalID: id)
    }

    /// The 401(k)'s buys on the 8th are its paycheck's, split theirs and the
    /// company's as the settings split them; the 22nd's never synced, so it's
    /// the expected amount, marked estimated (round 3).
    @Test func a401kTakesEachPaychecksBuysOrTheExpectedAmount() throws {
        let transactions = [
            paycheck(day(2026, 10, 6), 1_950), paycheck(day(2026, 10, 20), 2_039.50),
            buy(day(2026, 10, 8), -290, "a"), buy(day(2026, 10, 8), -60, "b")
        ]
        let k401 = try #require(report(transactions).first { $0.accountID == plan.id }?.months.first)
        #expect(k401.payroll == PayrollMoney(employee: 355, employer: 355, estimated: true))
        #expect(k401.moneyIn == 710)
        #expect(k401.marketChange == 290)
        // The stock plan reports no buys: each paycheck since its first balance, from the settings.
        let stock = try #require(report(transactions).first { $0.accountID == espp.id }?.months.first)
        #expect(stock.payroll == PayrollMoney(employee: 50, employer: 7.50, estimated: true))
    }

    @Test func buysForEveryPaycheckArentEstimated() throws {
        let transactions = [
            paycheck(day(2026, 10, 6), 1_950), paycheck(day(2026, 10, 20), 2_039.50),
            buy(day(2026, 10, 8), -350, "a"), buy(day(2026, 10, 22), -360, "b")
        ]
        let k401 = try #require(report(transactions).first { $0.accountID == plan.id }?.months.first)
        #expect(k401.payroll == PayrollMoney(employee: 355, employer: 355, estimated: false))
    }

    /// Paid weekly, a buy belongs to one paycheck only.
    @Test func weeklyPaydaysDontShareABuy() throws {
        var weekly = profile
        weekly.everyDays = 7
        let firstBalances = Dictionary(snapshots.map { ($0.accountID, $0.day) }, uniquingKeysWith: min)
        let transactions = [paycheck(day(2026, 10, 13), 1_000), paycheck(day(2026, 10, 20), 1_000), buy(day(2026, 10, 19), -100, "a")]
        let payroll = Pay.payroll(
            profile: weekly, transactions: transactions, firstBalances: firstBalances, kinds: [:],
            months: october...october, today: today)
        let actual = (payroll.deposits[plan.id] ?? []).filter { !$0.money.estimated }
        #expect(actual.count == 1 && actual.first?.money.total == 100)
    }

    /// An account linked after a month's last payday took in nothing from pay
    /// that month: $0, told, so it counts in an invested goal's pace (round 3 re-audit).
    @Test func noPaydayAfterTheFirstBalanceIsNothingIn() throws {
        let september = Month(year: 2026, month: 9)
        let late = [
            BalanceSnapshot(accountID: espp.id, day: day(2026, 9, 27), source: .simplefin, balance: 1_000),
            BalanceSnapshot(accountID: espp.id, day: day(2026, 10, 30), source: .simplefin, balance: 1_200)
        ]
        let transactions = [paycheck(day(2026, 9, 22), 1_950), paycheck(day(2026, 10, 6), 1_950), paycheck(day(2026, 10, 20), 2_039.50)]
        let payroll = Pay.payroll(
            profile: profile, transactions: transactions, firstBalances: [espp.id: day(2026, 9, 27)],
            kinds: [:], months: september...october, today: today)
        let months =
            Contributions.report(
                accounts: [espp], snapshots: late, transactions: transactions, kinds: [:], today: today,
                months: september...october, payroll: payroll
            ).first?.months ?? []
        #expect(months.first?.netContributions == 0)
        #expect(months.last?.payroll == PayrollMoney(employee: 100, employer: 15, estimated: true))
    }

    /// Linked between a payday and its buys: the buys after the first balance
    /// are that paycheck's money in, dated from the first balance.
    @Test func buysAfterTheFirstBalanceCountForAPaydayBefore() throws {
        let balances = [
            BalanceSnapshot(accountID: plan.id, day: day(2026, 10, 9), source: .simplefin, balance: 20_000),
            BalanceSnapshot(accountID: plan.id, day: day(2026, 10, 30), source: .simplefin, balance: 21_000)
        ]
        let transactions = [
            paycheck(day(2026, 10, 6), 1_950), paycheck(day(2026, 10, 20), 2_039.50),
            buy(day(2026, 10, 7), -50, "before"), buy(day(2026, 10, 10), -300, "a"), buy(day(2026, 10, 22), -360, "b")
        ]
        let payroll = Pay.payroll(
            profile: profile, transactions: transactions, firstBalances: [plan.id: day(2026, 10, 9)],
            kinds: [:], months: october...october, today: today)
        let k401 = try #require(
            Contributions.report(
                accounts: [plan], snapshots: balances, transactions: transactions, kinds: [:],
                today: today, months: october...october, payroll: payroll
            ).first?.months.first)
        #expect(k401.moneyIn == 660)
        #expect(k401.payroll?.estimated == false)
    }

    /// A payday in the month before keeps its buys that land after the first balance.
    @Test func aPaydayBeforeTheMonthKeepsItsBuysInIt() throws {
        let balances = [
            BalanceSnapshot(accountID: plan.id, day: day(2026, 10, 1), source: .simplefin, balance: 20_000),
            BalanceSnapshot(accountID: plan.id, day: day(2026, 10, 30), source: .simplefin, balance: 21_000)
        ]
        // Paid every other Tuesday from Sep 29: its buys land Oct 2, after the Oct 1 first balance.
        var shifted = profile
        shifted.knownPayday = day(2026, 9, 29)
        let transactions = [
            paycheck(day(2026, 10, 13), 1_950), paycheck(day(2026, 10, 27), 2_039.50),
            buy(day(2026, 10, 2), -300, "a"), buy(day(2026, 10, 13), -350, "b"), buy(day(2026, 10, 27), -360, "c")
        ]
        let payroll = Pay.payroll(
            profile: shifted, transactions: transactions, firstBalances: [plan.id: day(2026, 10, 1)],
            kinds: [:], months: october...october, today: today)
        let k401 = try #require(
            Contributions.report(
                accounts: [plan], snapshots: balances, transactions: transactions, kinds: [:],
                today: today, months: october...october, payroll: payroll
            ).first?.months.first)
        #expect(k401.moneyIn == 1_010)
    }

    /// A payday with no paycheck and no buys can't be told: the month reads
    /// the account's transactions as before.
    @Test func aPaydayWithNoPaycheckFallsBackToTransactions() throws {
        let transactions = [buy(day(2026, 9, 10), -340, "s"), paycheck(day(2026, 10, 6), 1_950), buy(day(2026, 10, 8), -350, "a")]
        let k401 = try #require(report(transactions).first { $0.accountID == plan.id }?.months.first)
        #expect(k401.payroll == nil)
        #expect(k401.moneyIn == 350)
    }
}

@Suite struct SavingsRateTests {
    /// (500 moved + 2 checks × (180 + 180 match + 50 + 7.50 company)) over
    /// 2 checks × (3,000 + 180 match), and moved over what was deposited.
    @Test func aMonthsRateIsSavingsOverSalaryAndTheMatch() throws {
        let found = Pay.paychecks(in: [paycheck(day(2026, 10, 6), 1_950), paycheck(day(2026, 10, 20), 2_039.50)], profile: payProfile)
        let rate = try #require(
            SavingsRate.month(
                Month(year: 2026, month: 10), profile: payProfile, paychecks: found,
                moved: 500, today: day(2026, 10, 31)))
        #expect(rate.saved == 1_335)
        #expect(rate.earned == 6_360)
        #expect(rate.takeHome == 3_989.50)
        #expect(rate.ofGross == Decimal(1_335) / 6_360)
        #expect(rate.ofTakeHome == Decimal(500) / Decimal(string: "3989.50")!)
        // Paydays after today don't count yet; without settings there's no rate.
        let early = SavingsRate.month(Month(year: 2026, month: 10), profile: payProfile, paychecks: found, moved: 0, today: day(2026, 10, 10))
        #expect(early?.earned == 3_180)
        #expect(SavingsRate.month(Month(year: 2026, month: 10), profile: PayProfile(), paychecks: found, moved: 0, today: day(2026, 10, 31)) == nil)
    }

    /// Every transfer from their everyday accounts into a savings or investing
    /// account counts, budgeted or not, net of what came back out to them in
    /// the same month (round 4: "Oct 2 $300 to Travel Fund, Oct 6 $300 back
    /// to Main"); moves between saving accounts aren't new saving.
    @Test func movedCountsEveryTransferIntoSavingsAndInvesting() {
        let checking = Account(name: "Checking", accountClass: .cash, source: .simplefin)
        let emergency = Account(name: "Emergency Fund", accountClass: .cash, source: .simplefin)
        let brokerage = Account(name: "Brokerage", accountClass: .taxable, source: .simplefin)
        let roth = Account(name: "Roth IRA", accountClass: .retirement, source: .simplefin)
        let k401 = Account(name: "401(k)", accountClass: .retirement, source: .simplefin)
        let stock = Account(name: "ESPP", accountClass: .taxable, source: .simplefin)
        let venmo = Account(name: "Venmo", accountClass: .cash, source: .simplefin)
        var profile = payProfile
        profile.retirementAccountID = k401.id
        profile.stockAccountID = stock.id
        func move(_ from: Account, _ to: Account, _ amount: Decimal, _ day: Int) -> [Transaction] {
            [
                Transaction(
                    accountID: from.id, day: Day(year: 2026, month: 10, day: day), amount: -amount, merchant: "Transfer",
                    category: "Transfer", externalID: "o\(day)"),
                Transaction(
                    accountID: to.id, day: Day(year: 2026, month: 10, day: day), amount: amount, merchant: "Transfer",
                    category: "Transfer", externalID: "i\(day)")
            ]
        }
        let transactions =
            [paycheck(day(2026, 10, 6), 2_000, account: checking.id)]
            + (3...5).map {
                Transaction(
                    accountID: checking.id, day: day(2026, 10, $0), amount: -50, merchant: "Grocer",
                    category: "Groceries", externalID: "g\($0)")
            }
            + [
                Transaction(
                    accountID: emergency.id, day: day(2026, 10, 31), amount: 2, merchant: "Interest",
                    category: "Interest", externalID: "int"),
                // Part of a paycheck deposited straight into savings is saved, and doesn't make it an everyday account.
                paycheck(day(2026, 10, 6), 150, account: emergency.id),
                // A bank fee doesn't either.
                Transaction(
                    accountID: emergency.id, day: day(2026, 10, 15), amount: -5, merchant: "Fee",
                    category: "Fees", externalID: "fee"),
                // A contribution from a bank Compass can't see has no partner, and still counts.
                Transaction(
                    accountID: roth.id, day: day(2026, 10, 16), amount: 1_000, merchant: "Cash Contribution Current Year",
                    category: "Transfer", externalID: "contribution")
            ]
            // An everyday account whose charges aren't filed yet isn't savings.
            + (17...19).map { Transaction(accountID: venmo.id, day: day(2026, 10, $0), amount: -12, merchant: "Lunch", externalID: "v\($0)") }
            + move(checking, brokerage, 500, 8) + move(checking, emergency, 198, 9) + move(checking, venmo, 60, 10)
            + move(emergency, checking, 300, 12) + move(brokerage, roth, 1_000, 14)
            // Selling stock plan shares into the brokerage was counted as it went in.
            + move(stock, brokerage, 700, 20)
        let saving = SavingsRate.savingAccounts(
            [checking, emergency, brokerage, roth, k401, stock, venmo], transactions: transactions,
            kinds: [:], profile: profile)
        #expect(saving == [emergency.id, brokerage.id, roth.id])
        // Emergency fund 150 + 198 − 300 back = 48, brokerage 500, Roth 1,000.
        #expect(SavingsRate.moved(transactions, kinds: [:], into: saving, profile: profile) == [Month(year: 2026, month: 10): 1_548])
    }

    /// Their October: $300 to the travel fund on the 2nd came back on the 6th,
    /// so nothing was saved there; a month's net never goes below zero, and
    /// money back the month after isn't taken off the month before.
    @Test func moneyThatCameBackIsntSaved() {
        let checking = UUID(), travel = UUID()
        func move(_ from: UUID, _ to: UUID, _ amount: Decimal, _ month: Int, _ day: Int) -> [Transaction] {
            [
                Transaction(
                    accountID: from, day: Day(year: 2026, month: month, day: day), amount: -amount, merchant: "Transfer",
                    category: "Transfer", externalID: "o\(month)-\(day)"),
                Transaction(
                    accountID: to, day: Day(year: 2026, month: month, day: day), amount: amount, merchant: "Transfer",
                    category: "Transfer", externalID: "i\(month)-\(day)")
            ]
        }
        let transactions =
            move(checking, travel, 300, 10, 2) + move(travel, checking, 300, 10, 6)
            + move(checking, travel, 300, 9, 30) + move(travel, checking, 300, 11, 3)
        let moved = SavingsRate.moved(transactions, kinds: [:], into: [travel], profile: payProfile)
        #expect(moved[Month(year: 2026, month: 10)] == 0)
        #expect(moved[Month(year: 2026, month: 9)] == 300)
        #expect((moved[Month(year: 2026, month: 11)] ?? 0) == 0)
    }

    @Test func ratesAddUp() {
        let total = SavingsRate.total([
            SavingsRate(saved: 100, earned: 1_000, moved: 50, takeHome: 500),
            SavingsRate(saved: 300, earned: 1_000, moved: 150, takeHome: 500)
        ])
        #expect(total == SavingsRate(saved: 400, earned: 2_000, moved: 200, takeHome: 1_000))
    }
}

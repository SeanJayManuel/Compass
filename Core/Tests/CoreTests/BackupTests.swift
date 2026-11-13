import Core
import Foundation
import Testing

@Suite struct BackupTests {
    /// Daily backups (Oct 31, 2026, after an old build dropped the Playbook):
    /// one a day by name, the newest two weeks kept, other files left alone.
    @Test func dailyBackupsKeepTheNewestTwoWeeks() {
        #expect(Backup.dailyName(for: Day(year: 2026, month: 11, day: 3)) == "compass-backup-2026-11-03.json")
        let names = (1...20).map { Backup.dailyName(for: Day(year: 2026, month: 10, day: $0)) } + ["notes.txt"]
        let expired = Backup.expiredDaily(names.shuffled(), keep: 14)
        #expect(expired == (1...6).map { Backup.dailyName(for: Day(year: 2026, month: 10, day: $0)) })
    }

    let checking = Account(name: "Checking, joint", institution: "Example \"Big\" Bank", accountClass: .cash, source: .simplefin)

    @Test func csvFieldsWithCommasQuotesOrNewlinesAreQuoted() {
        #expect(Backup.csvField("plain") == "plain")
        #expect(Backup.csvField("a, b") == "\"a, b\"")
        #expect(Backup.csvField("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(Backup.csvField("two\nlines") == "\"two\nlines\"")
    }

    @Test func amountsAreWrittenExactlyWithTwoDecimals() {
        #expect(Backup.amount(Decimal(string: "-12.4")!) == "-12.40")
        #expect(Backup.amount(Decimal(string: "1234567.891")!) == "1234567.89")
        #expect(Backup.amount(0) == "0.00")
    }

    @Test func balancesExportAsOneRowPerSnapshotWithTheAccountName() {
        let csv = Backup.balancesCSV(
            snapshots: [BalanceSnapshot(accountID: checking.id, day: Day(year: 2026, month: 10, day: 1), source: .simplefin, balance: 1500)],
            accounts: [checking]
        )
        #expect(csv == "Date,Account,Institution,Source,Balance\n2026-10-01,\"Checking, joint\",\"Example \"\"Big\"\" Bank\",simplefin,1500.00\n")
    }

    @Test func transactionsExportNewestFirst() {
        let older = Transaction(
            accountID: checking.id, day: Day(year: 2026, month: 9, day: 1), amount: -5, merchant: "Cafe",
            category: "Coffee", externalID: "a")
        let newer = Transaction(
            accountID: checking.id, day: Day(year: 2026, month: 10, day: 1), amount: 100, merchant: "Payroll",
            category: nil, externalID: "b")
        var split = Transaction(
            accountID: checking.id, day: Day(year: 2026, month: 8, day: 1), amount: -100, merchant: "Target",
            category: "Household", externalID: "c")
        split.splits = [TransactionSplit(category: "Groceries", amount: -40), TransactionSplit(category: "Household", amount: -60)]
        let travel = Goal(name: "$5K Travel Fund", kind: .accountTotal([checking.id]), target: 5_000)
        var flight = Transaction(
            accountID: checking.id, day: Day(year: 2026, month: 7, day: 1), amount: -400, merchant: "Air Canada",
            category: "Travel", externalID: "d")
        flight.paidFromGoal = travel.id
        flight.paidFromGoalAmount = 250
        let csv = Backup.transactionsCSV([older, newer, split, flight], accounts: [checking], goals: [travel])
        // A split's parts go in a column of their own, as does the goal that paid (seam 44).
        #expect(
            csv == """
                Date,Account,Merchant,Statement,Category,Amount,Splits,Paid from goal
                2026-10-01,"Checking, joint",Payroll,,,100.00,,
                2026-09-01,"Checking, joint",Cafe,,Coffee,-5.00,,
                2026-08-01,"Checking, joint",Target,,Household,-100.00,Groceries -40.00; Household -60.00,
                2026-07-01,"Checking, joint",Air Canada,,Travel,-400.00,,$5K Travel Fund 250.00

                """)
    }

    @Test func theBundleRoundTripsEverything() throws {
        let bundle = BackupBundle(
            exportedAt: Date(timeIntervalSince1970: 1_792_500_000),
            accounts: [checking],
            snapshots: ["0.10", "-0.01", "1234567.89"].enumerated().map { offset, balance in
                BalanceSnapshot(
                    accountID: checking.id, day: Day(year: 2026, month: 10, day: 1 + offset), source: .manual,
                    balance: Decimal(string: balance)!)
            },
            transactions: [], goals: [Goal(name: "$100K", kind: .netWorth, target: 100_000, note: "By my 30th birthday")],
            budget: BudgetSchedule(BudgetPlan(flexibleBudget: 1800)), categoryRules: ["chipotle": "Restaurants"],
            categoryKinds: ["Paychecks": .income], lifeGoals: [], habits: [], list: [], vision: "Rested",
            reminderMeasures: [ReminderMeasure(reminderID: "x", title: "$50k net worth", measure: .netWorth, target: 50_000)],
            playbook: [
                PlaybookEntry(
                    area: "Hair", kind: .routine, title: "Shower",
                    steps: [PlaybookStep(text: "Shampoo", weekdays: [0, 3]), PlaybookStep(text: "Conditioner")]),
                PlaybookEntry(
                    area: "Grooming", kind: .pick, title: "Nails", repeatEveryDays: 10,
                    lastDone: Day(year: 2026, month: 10, day: 22))
            ],
            sizes: PlaybookSizes(rows: [PlaybookSize(label: "Suit", value: "38S")], note: "Everlane tees run small"),
            yearlyBets: [YearlyBets(year: 2026, bets: ["Gym consistency", "Career progress"])],
            paystubs: [try Paystub.parse(sampleStubText)],
            pay: {
                var profile = PayProfile()
                profile.retirementAccountID = checking.id
                profile.expected = [ExpectedPay(kind: .vest, title: "RSU grant", day: nil, gross: 25_000)]
                return profile
            }(),
            notes: [
                Note(
                    topic: "Money", title: "Buffer", body: "Keep a month in checking, \"just in case\"",
                    updatedAt: Date(timeIntervalSince1970: 1_792_400_000))
            ]
        )
        let decoded = try Backup.decode(try Backup.json(bundle))
        #expect(decoded == bundle)
    }
}

/// Backups written before quarter reminders could follow a number, or before
/// the Playbook or notes, still read back, with none.
@Suite struct BackupReminderMeasureCompatibilityTests {
    @Test func aBackupWithoutMoneyLinksReadsBackWithNone() throws {
        let bundle = BackupBundle(
            exportedAt: Date(timeIntervalSince1970: 1_792_500_000), accounts: [], snapshots: [],
            transactions: [], goals: [], budget: nil, lifeGoals: [], habits: [], list: [], vision: "")
        var object = try JSONSerialization.jsonObject(with: Backup.json(bundle)) as! [String: Any]
        object.removeValue(forKey: "reminderMeasures")
        object.removeValue(forKey: "playbook")
        object.removeValue(forKey: "sizes")
        object.removeValue(forKey: "yearlyBets")
        object.removeValue(forKey: "paystubs")
        object.removeValue(forKey: "pay")
        object.removeValue(forKey: "notes")
        let older = try JSONSerialization.data(withJSONObject: object)
        #expect(try Backup.decode(older) == bundle)
    }

    @Test func aMoneyLinkFromBeforeRewardsReadsBackWithNone() throws {
        let link = ReminderMeasure(reminderID: "x", title: "$50k net worth", measure: .netWorth, target: 50_000)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(link)) as! [String: Any]
        #expect(object.removeValue(forKey: "reward") == nil)
        let older = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(ReminderMeasure.self, from: older) == link)
        var rewarded = link
        rewarded.reward = Reward(name: "Weekend away", cost: 900, claimedOn: Day(year: 2026, month: 11, day: 1))
        #expect(try JSONDecoder().decode(ReminderMeasure.self, from: JSONEncoder().encode(rewarded)) == rewarded)
    }
}

/// Backups written before accounts remembered merged SimpleFIN feeds still
/// read back, with none.
@Suite struct BackupAccountCompatibilityTests {
    @Test func aGoalWithoutANoteDecodes() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"$100K","kind":{"netWorth":{}},"target":100000,"status":{"active":{}}}"#
        let goal = try JSONDecoder().decode(Goal.self, from: Data(json.utf8))
        #expect(goal.note == "")
        #expect(goal.target == 100_000)
    }

    @Test func anAccountWithoutMergedFeedsDecodes() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Checking","accountClass":"cash","source":"simplefin","excludedFromNetWorth":false}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        #expect(account.mergedExternalIDs.isEmpty)
    }
}

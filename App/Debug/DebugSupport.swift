#if DEBUG
    import AppKit
    import Core
    import Foundation
    import SwiftData

    /// Launch options for design review on sandbox data. Debug builds only.
    ///
    /// - `--appearance light|dark` forces the appearance.
    /// - `--seed-demo` opens a separate demo store (Compass-Demo.store) and fills
    ///   it with three years of fake history and sample goals. Each seed step
    ///   adds only what's missing, so a demo store made by an older build picks
    ///   up newer seed data; `--reset-demo` starts it over.
    enum DebugSupport {
        /// `--reset-demo`: deletes the demo store (and its cache) before it opens,
        /// so `--seed-demo` starts fresh. Only ever the demo store.
        static func resetDemoIfRequested() {
            let arguments = CommandLine.arguments
            guard DataEnvironment.current == .sandbox, arguments.contains("--seed-demo"), arguments.contains("--reset-demo") else { return }
            let store = DataEnvironment.current.storeURL
            guard store.lastPathComponent == "Compass-Demo.store" else { return }
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: store.path + suffix))
            }
            try? FileManager.default.removeItem(at: store.deletingPathExtension().appendingPathExtension("cache.json"))
        }

        /// `--scroll-test`: the money overview scrolls itself top to bottom and
        /// back, over and over, so Instruments can record scrolling hitches
        /// without anyone at the trackpad. Sandbox only.
        static var scrollTest: Bool {
            DataEnvironment.current == .sandbox && CommandLine.arguments.contains("--scroll-test")
        }

        /// `--open-goal "<name>"`: Goals opens on the page of the goal with that
        /// name, so a snapshot can render it. Sandbox only.
        static var openGoalName: String? {
            guard DataEnvironment.current == .sandbox else { return nil }
            let arguments = CommandLine.arguments
            guard let flag = arguments.firstIndex(of: "--open-goal"), arguments.indices.contains(flag + 1) else { return nil }
            return arguments[flag + 1]
        }

        /// `--open-search "<text>"`: the search panel opens with that typed, so
        /// a snapshot can render it. Sandbox only.
        static var openSearchText: String? {
            guard DataEnvironment.current == .sandbox else { return nil }
            let arguments = CommandLine.arguments
            guard let flag = arguments.firstIndex(of: "--open-search"), arguments.indices.contains(flag + 1) else { return nil }
            return arguments[flag + 1]
        }

        /// Opens the newest page's matching merchant in Transactions details.
        static var openTransactionName: String? {
            guard DataEnvironment.current == .sandbox else { return nil }
            let arguments = CommandLine.arguments
            guard let flag = arguments.firstIndex(of: "--open-transaction"), arguments.indices.contains(flag + 1) else { return nil }
            return arguments[flag + 1]
        }

        /// Opens a waiting Review row by its exact merchant, for layout checks.
        static var openReviewName: String? {
            guard DataEnvironment.current == .sandbox else { return nil }
            let arguments = CommandLine.arguments
            guard let flag = arguments.firstIndex(of: "--open-review"), arguments.indices.contains(flag + 1) else { return nil }
            return arguments[flag + 1]
        }

        static func prepare(container: ModelContainer) {
            guard DataEnvironment.current == .sandbox else { return }
            let arguments = CommandLine.arguments

            if let flag = arguments.firstIndex(of: "--appearance"), arguments.indices.contains(flag + 1) {
                let name: NSAppearance.Name = arguments[flag + 1] == "dark" ? .darkAqua : .aqua
                DispatchQueue.main.async { NSApp.appearance = NSAppearance(named: name) }
            }

            if arguments.contains("--seed-perf") {
                seedPerf(container.mainContext)
                if arguments.contains("--seed-only") { exit(0) }
            }

            if arguments.contains("--seed-demo") {
                seed(container.mainContext)
                seedGoals(container.mainContext)
                seedTransactions(container.mainContext)
                seedTransfers(container.mainContext)
                seedContributions(container.mainContext)
                seedCardHistory(container.mainContext)
                seedLife(container.mainContext)
                seedPay(container.mainContext)
                seedHabits(container.mainContext)
                seedPlaybook(container.mainContext)
                seedNotes(container.mainContext)
            }
        }

        /// A year of made-up spending: a few categories with steady, varied
        /// amounts, paid from checking, and two paychecks a month.
        private static func seedTransactions(_ context: ModelContext) {
            replaceRandomPaychecks(context)
            // Its own rows only: seedTransfers' rows don't count.
            var own = FetchDescriptor<TransactionRecord>(
                predicate: #Predicate {
                    $0.externalID.starts(with: "seed:") && !$0.externalID.starts(with: "seed:xfer:")
                })
            own.fetchLimit = 1
            guard (try? context.fetchCount(own)) == 0,
                let accounts = try? CompassStore(context: context).accounts(),
                let card = accounts.first(where: { $0.name == "Everyday Checking" }) ?? accounts.first
            else { return }
            let today = Day(.now, in: .current)
            let merchants: [(String, String, Int)] = [
                ("Neighborhood Grocer", "Groceries", 9_000), ("Corner Bistro", "Restaurants & Bars", 4_500),
                ("Blue Cup Coffee", "Coffee Shops", 600), ("Hardware Co", "Shopping", 6_000),
                ("Rail Pass", "Travel", 12_000), ("Card Payment", "Credit Card Payment", 150_000),
                ("Laundromat", "Laundry", 900), ("Rideshare", "Taxi and Rideshare", 1_800), ("Pharmacy", "Personal", 1_500)
            ]
            var state: UInt64 = 7
            func next() -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int(state >> 33) }
            var transactions: [Transaction] = []
            for dayOffset in 0..<365 {
                let day = Day(ordinal: today.ordinal - dayOffset)
                for (merchant, category, typical) in merchants where next() % 7 == 0 {
                    let cents = typical / 2 + next() % max(typical, 1)
                    let uncategorized = dayOffset < 20 && merchant == "Hardware Co"
                    transactions.append(
                        Transaction(
                            accountID: card.id, day: day, amount: -Decimal(cents) / 100,
                            merchant: merchant, category: uncategorized ? nil : category,
                            externalID: "seed:\(dayOffset):\(merchant)"
                        ))
                }
            }
            // The newest big grocery run was part shopping (seam 43).
            if let index = transactions.firstIndex(where: { $0.category == "Groceries" && $0.amount < -60 && $0.day.ordinal < today.ordinal - 3 }),
                let split = try? Splits.split(transactions[index], into: [("Groceries", -transactions[index].amount - 30), ("Shopping", 30)], kinds: [:])
            {
                transactions[index] = split
            }
            let store = CompassStore(context: context)
            // The last three days are new, waiting in review.
            let recent = today.ordinal - 3
            try? store.insert(transactions.filter { $0.day.ordinal <= recent })
            try? store.insert(transactions.filter { $0.day.ordinal > recent }, pendingReview: true)
            // Monthly bills and paychecks (negative cents are money in) on fixed
            // days, and a starting budget.
            for monthsBack in 0..<12 {
                let month = Month(today).adding(-monthsBack)
                for (merchant, category, day, cents) in [
                    ("Landlord", "Rent", 1, 210_000), ("Fiber Co", "Internet", 28, 7_000),
                    ("Streaming", "Subscriptions", 12, 2_400)
                ] {
                    let date = Day(year: month.year, month: month.month, day: day)
                    guard date <= today else { continue }
                    store.insertSeed(
                        Transaction(
                            accountID: card.id, day: date, amount: -Decimal(cents) / 100, merchant: merchant,
                            category: category, externalID: "seed:bill:\(monthsBack):\(merchant):\(day)"))
                }
            }
            // Paychecks every other Tuesday, two days before the Thursday payday seedPay sets.
            for back in 0..<27 {
                let date = Day(ordinal: lastPayday(today).ordinal - 2 - 14 * back)
                guard date <= today else { continue }
                store.insertSeed(
                    Transaction(
                        accountID: card.id, day: date, amount: 2_600, merchant: "Payroll",
                        category: "Paychecks", externalID: "seed:bill:pay:\(back)"))
            }
            try? context.save()
            // A plan from an older seed keeps its edits and gains planned income.
            if (try? context.fetchCount(FetchDescriptor<BudgetRecord>())) == 0 {
                try? store.save(
                    BudgetSchedule(
                        BudgetPlan(
                            flexibleBudget: 1_800, expected: ["Rent": 2_100, "Internet": 70, "Subscriptions": 24],
                            plannedIncome: ["Paychecks": 5_200])))
            } else if let schedule = try? store.budgetSchedule(), schedule.plan(for: Month(Day(.now, in: .current))).plannedIncome.isEmpty {
                try? store.save(schedule.changing(Month(year: 2000, month: 1), .onward) { $0.plannedIncome = ["Paychecks": 5_200] })
            }
        }

        /// Demo stores seeded before Oct 21, 2026 drew "Payroll" at random (about
        /// half of it money out) and had no paychecks on the 1st and 15th. Their
        /// seeded spending and bills are removed so seedTransactions lays them
        /// down again; transfers, rules and the budget plan stay.
        private static func replaceRandomPaychecks(_ context: ModelContext) {
            var random = FetchDescriptor<TransactionRecord>(
                predicate: #Predicate {
                    $0.merchant == "Payroll" && $0.externalID.starts(with: "seed:") && !$0.externalID.starts(with: "seed:bill:")
                })
            random.fetchLimit = 1
            guard ((try? context.fetchCount(random)) ?? 0) > 0 else { return }
            let old =
                (try? context.fetch(
                    FetchDescriptor<TransactionRecord>(
                        predicate: #Predicate {
                            $0.externalID.starts(with: "seed:") && !$0.externalID.starts(with: "seed:xfer:")
                        }))) ?? []
            for record in old { context.delete(record) }
            try? context.save()
            FileHandle.standardError.write(Data("[demo] replaced \(old.count) transactions from an older demo seed\n".utf8))
        }

        /// The Rewards Card began with one balance, today's, so demo net worth
        /// fell by its balance on the last day. A balance on the first day of the
        /// demo history and on each month's 1st since, up to its latest balance,
        /// keeps the debt in the whole series. Those days hold the seed's
        /// balances; a store that already has them is left as it is.
        private static func seedCardHistory(_ context: ModelContext) {
            guard let accounts = try? CompassStore(context: context).accounts(),
                let card = accounts.first(where: { $0.name == "Rewards Card" })
            else { return }
            let cardID = card.id
            let manual = BalanceSource.manual.rawValue
            let own = (try? context.fetch(FetchDescriptor<SnapshotRecord>(predicate: #Predicate { $0.accountID == cardID }))) ?? []
            var earliest = FetchDescriptor<SnapshotRecord>(
                predicate: #Predicate { $0.accountID != cardID },
                sortBy: [SortDescriptor(\.dayOrdinal)])
            earliest.fetchLimit = 1
            guard let start = (try? context.fetch(earliest))?.first?.dayOrdinal,
                let latest = own.map(\.dayOrdinal).max(), start < latest
            else { return }
            var days = [Day(ordinal: start)]
            var month = Month(Day(ordinal: start)).adding(1)
            while Day(year: month.year, month: month.month, day: 1).ordinal < latest {
                days.append(Day(year: month.year, month: month.month, day: 1))
                month = month.adding(1)
            }
            let existing = Dictionary(own.filter { $0.sourceRaw == manual }.map { ($0.dayOrdinal, $0) }, uniquingKeysWith: { first, _ in first })
            // Between $1,050 and $1,310 owed, wandering a little month to month.
            let wander = [0, 60, 140, 90, 180, 230, 150, 70, 120, 200, 260, 170]
            for (index, day) in days.enumerated() {
                let balance = -Decimal(1_050 + wander[index % wander.count])
                if let record = existing[day.ordinal] {
                    if record.balance != balance { record.balance = balance }
                } else {
                    context.insert(SnapshotRecord(BalanceSnapshot(accountID: cardID, day: day, source: .manual, balance: balance)))
                }
            }
            if context.hasChanges { try? context.save() }
        }

        /// Money that isn't spending, to check Spending against: a stock buy
        /// filed under Buy each month, moves into savings and card payments that
        /// arrive uncategorized (as SimpleFIN sends them, for Find transfers),
        /// and a monthly Anthropic charge filed under Miscellaneous (to refile).
        /// Separate from seedTransactions so older demo stores get them too.
        private static func seedTransfers(_ context: ModelContext) {
            var seeded = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.externalID.starts(with: "seed:xfer:") })
            seeded.fetchLimit = 1
            guard (try? context.fetchCount(seeded)) == 0, let accounts = try? CompassStore(context: context).accounts(),
                let checking = accounts.first(where: { $0.name == "Everyday Checking" }),
                let savings = accounts.first(where: { $0.name == "High-Yield Savings" }),
                let brokerage = accounts.first(where: { $0.name == "Brokerage" })
            else { return }
            let today = Day(.now, in: .current)
            let card: Account
            if let existing = accounts.first(where: { $0.name == "Rewards Card" }) {
                card = existing
            } else {
                card = Account(name: "Rewards Card", institution: "Example Bank", accountClass: .debt, source: .manual)
                context.insert(AccountRecord(card))
                context.insert(SnapshotRecord(BalanceSnapshot(accountID: card.id, day: today, source: .manual, balance: -1_240)))
            }
            let store = CompassStore(context: context)
            for monthsBack in 0..<6 {
                let month = Month(today).adding(-monthsBack)
                func on(_ day: Int) -> Day? {
                    let date = Day(year: month.year, month: month.month, day: min(day, month.daysInMonth))
                    return date <= today ? date : nil
                }
                func add(_ account: Account, _ day: Day?, _ amount: Decimal, _ merchant: String, _ category: String?, _ tag: String) {
                    guard let day else { return }
                    store.insertSeed(
                        Transaction(
                            accountID: account.id, day: day, amount: amount, merchant: merchant,
                            category: category, externalID: "seed:xfer:\(monthsBack):\(tag)"))
                }
                add(brokerage, on(3), -1_000, "Index Fund Purchase", "Buy", "buy")
                add(card, on(9), -20, "Anthropic", "Miscellaneous", "ai")
                if on(16) != nil {
                    add(checking, on(15), -500, "Transfer to Savings", nil, "save-out")
                    add(savings, on(16), 500, "Transfer from Checking", nil, "save-in")
                }
                if on(22) != nil {
                    add(checking, on(20), -1_240, "Rewards Card Autopay", nil, "card-out")
                    add(card, on(22), 1_240, "Payment Thank You", nil, "card-in")
                }
            }
            try? context.save()
        }

        /// A monthly move from checking into the brokerage and a quarterly
        /// dividend, so `contributions` has their money and the market's to tell
        /// apart. A step of its own so older demo stores get them too.
        private static func seedContributions(_ context: ModelContext) {
            var seeded = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.externalID.starts(with: "seed:invest:") })
            seeded.fetchLimit = 1
            guard (try? context.fetchCount(seeded)) == 0, let accounts = try? CompassStore(context: context).accounts(),
                let checking = accounts.first(where: { $0.name == "Everyday Checking" }),
                let brokerage = accounts.first(where: { $0.name == "Brokerage" })
            else { return }
            let today = Day(.now, in: .current)
            let store = CompassStore(context: context)
            for monthsBack in 0..<6 {
                let month = Month(today).adding(-monthsBack)
                func add(_ account: Account, _ day: Int, _ amount: Decimal, _ merchant: String, _ category: String?, _ tag: String) {
                    let date = Day(year: month.year, month: month.month, day: day)
                    guard date <= today else { return }
                    store.insertSeed(
                        Transaction(
                            accountID: account.id, day: date, amount: amount, merchant: merchant,
                            category: category, externalID: "seed:invest:\(monthsBack):\(tag)"))
                }
                if Day(year: month.year, month: month.month, day: 6) <= today {
                    add(checking, 5, -750, "Transfer to Brokerage", "Transfer", "out")
                    add(brokerage, 6, 750, "Electronic Funds Received", "Transfer", "in")
                }
                if month.month % 3 == 0 { add(brokerage, 25, 84, "Dividend Received", "Dividends & Capital Gains", "div") }
            }
            try? context.save()
        }

        /// The M6 benchmark: 25 accounts with daily balances for 10 years (about
        /// 91,000 snapshots), 30,000 transactions and a few goals.
        private static func seedPerf(_ context: ModelContext) {
            guard (try? context.fetchCount(FetchDescriptor<AccountRecord>())) == 0 else { return }
            let today = Day(.now, in: .current)
            let snapshots = SyntheticData.dailySnapshots(accounts: 25, years: 10, endingOn: today)
            var order: [UUID] = []
            for snapshot in snapshots where order.last != snapshot.accountID { order.append(snapshot.accountID) }
            let classes = AccountClass.allCases
            var ids: [UUID: (UUID, AccountClass)] = [:]
            for (index, generated) in order.enumerated() {
                let accountClass = classes[index % classes.count]
                let account = Account(name: "Account \(index + 1)", accountClass: accountClass, source: .manual)
                context.insert(AccountRecord(account))
                ids[generated] = (account.id, accountClass)
            }
            for (index, snapshot) in snapshots.enumerated() {
                guard let (id, accountClass) = ids[snapshot.accountID] else { continue }
                let balance = accountClass == .debt ? -abs(snapshot.balance) : abs(snapshot.balance)
                context.insert(SnapshotRecord(BalanceSnapshot(accountID: id, day: snapshot.day, source: snapshot.source, balance: balance)))
                if index % 10_000 == 0 { try? context.save() }
            }
            let categories = [
                "Groceries", "Restaurants & Bars", "Coffee Shops", "Shopping", "Travel", "Gas", "Utilities",
                "Entertainment", "Health", "Home", "Gifts", "Subscriptions", "Paychecks", "Transfer"
            ]
            let firstAccount = ids.values.first!.0
            for index in 0..<30_000 {
                let day = Day(ordinal: today.ordinal - (index * 3653 / 30_000))
                let category = categories[index % categories.count]
                let cents = 500 + (index * 7919) % 20_000
                context.insert(
                    TransactionRecord(
                        Transaction(
                            accountID: firstAccount, day: day, amount: Decimal(category == "Paychecks" ? cents * 20 : -cents) / 100,
                            merchant: "Merchant \(index % 400)", category: category, externalID: "perf:\(index)"
                        )))
                if index % 10_000 == 0 { try? context.save() }
            }
            try? context.save()
            seedGoals(context)
        }

        /// Four made-up biweekly stubs ending last Thursday, none of them their.
        /// The latest Thursday before today (Thursday is weekday 3 counting Monday as 0).
        private static func lastPayday(_ today: Day) -> Day {
            let back = (Playbook.weekday(today) - 3 + 7) % 7
            return Day(ordinal: today.ordinal - (back == 0 ? 7 : back))
        }

        /// Made-up pay settings, paid every other Thursday; no paystubs.
        private static func seedPay(_ context: ModelContext) {
            guard (try? context.fetchCount(FetchDescriptor<PayProfileRecord>())) == 0 else { return }
            let store = CompassStore(context: context)
            let today = Day(.now, in: .current)
            var profile = PayProfile().guessingAccounts((try? store.accounts()) ?? [])
            profile.annualSalary = 78_000
            profile.knownPayday = lastPayday(today)
            profile.stockPerCheck = 50
            profile.stockCompanyPerCheck = 7.50
            profile.expected = [
                ExpectedPay(kind: .bonus, title: "Annual bonus", month: Month(year: today.year + 1, month: 3), gross: 9_000, estimate: true),
                ExpectedPay(kind: .vest, title: "RSU grant", day: nil, gross: 20_000, note: "Vesting schedule not set yet")
            ]
            try? store.save(profile)
        }

        private static func seedLife(_ context: ModelContext) {
            let store = CompassStore(context: context)
            if (try? context.fetchCount(FetchDescriptor<ReminderMeasureRecord>())) == 0 {
                // The sample quarter reminder "$150K net worth by year-end" follows net worth.
                try? store.save(ReminderMeasure(reminderID: "20", title: "$150K net worth by year-end", measure: .netWorth, target: 150_000))
            }
            if (try? context.fetchCount(FetchDescriptor<YearlyBetsRecord>())) == 0 {
                try? store.saveBets(
                    "Save $20K this year\nThe gym three times a week\nA few close friends nearby\nA promotion at work",
                    year: Day(.now, in: .current).year)
            }
            guard (try? context.fetchCount(FetchDescriptor<VisionRecord>())) == 0 else { return }
            try? store.saveVision(
                "Strong and rested. Close to a few people who know me well. Work I'm proud of, and enough room in the week to read, cook and be outside.")
        }

        /// Habits, one of them linked to a sample reminder. Separate
        /// from seedLife so demo stores made before habits existed get them too.
        private static func seedHabits(_ context: ModelContext) {
            let store = CompassStore(context: context)
            guard (try? context.fetchCount(FetchDescriptor<HabitRecord>())) == 0 else {
                // Demo stores from before habits could link to a reminder.
                for record in context.all(HabitRecord.self) {
                    guard var habit = record.habit, habit.title == "Journal", habit.reminder == nil else { continue }
                    habit.reminder = HabitReminder(id: "13", title: "Journal", listID: "daily")
                    try? store.save(habit)
                }
                return
            }
            let today = Day(.now, in: .current)
            // Most weeks hit, one missed a few weeks back, two days in so far this week.
            var gym = Habit(title: "Work out", perWeek: 4, startedOn: Day(ordinal: today.ordinal - 70))
            for weeksBack in 1...9 {
                let start = Week(today).start.ordinal - 7 * weeksBack
                let days = weeksBack == 4 ? [0, 3] : [0, 1, 3, 5]
                for offset in days { gym = Habits.toggle(gym, on: Day(ordinal: start + offset)) }
            }
            let start = Week(today).start.ordinal
            for offset in [0, 1] where start + offset <= today.ordinal { gym = Habits.toggle(gym, on: Day(ordinal: start + offset)) }
            // Linked to the sample "Journal" reminder in the sandbox.
            let journal = Habit(
                title: "Journal", perWeek: 3, startedOn: Day(ordinal: today.ordinal - 14),
                reminder: HabitReminder(id: "13", title: "Journal", listID: "daily"))
            try? store.save(gym)
            try? store.save(journal)

        }

        /// A few notes across topics, added by title so older demo stores get them.
        private static func seedNotes(_ context: ModelContext) {
            let store = CompassStore(context: context)
            let existing = Set(((try? store.notes()) ?? []).map(\.title))
            let day: TimeInterval = 86_400
            let notes = [
                Note(
                    topic: "Money", title: "Cash buffer",
                    body: "Keep a month of spending in checking so a late paycheck never means using the card. Anything above that goes to the brokerage.",
                    updatedAt: .now - 3 * day),
                Note(
                    topic: "Money", title: "Cards",
                    body: "Pay every card in full each month. Use the Sapphire for travel and dining only; everything else on the debit card.",
                    updatedAt: .now - 20 * day),
                Note(
                    topic: "Goals", title: "Why a house fund",
                    body: "Buying near family matters more than the timeline. Don't speed it up by cutting retirement contributions.", updatedAt: .now - 9 * day
                ),
                Note(
                    topic: "Career", title: "Next role",
                    body: "Aiming for a senior role on a product team, not management yet. Take on projects that ship to customers.", updatedAt: .now - 1 * day),
                Note(topic: "Life", title: "Weekends", body: "Keep Sundays unscheduled. Errands go on Saturday mornings.", updatedAt: .now - 14 * day)
            ]
            for note in notes where !existing.contains(note.title) { try? store.save(note) }
        }

        /// Sizes, picks and routines across a few areas, a workout split among
        /// them, and a pick from the demo's Pharmacy so a restock line shows.
        /// Entries are added by title, so older demo stores get new ones.
        private static func seedPlaybook(_ context: ModelContext) {
            let store = CompassStore(context: context)
            let today = Day(.now, in: .current)
            let existing = Set(((try? store.playbook()) ?? []).map(\.title))
            if existing.isEmpty {
                try? store.save(
                    PlaybookSizes(
                        rows: [
                            PlaybookSize(label: "T-shirt", value: "M"), PlaybookSize(label: "Button-up", value: "15 / 34"),
                            PlaybookSize(label: "Jeans", value: "31 × 32, slim"), PlaybookSize(label: "Suit", value: "38S · 32 waist"),
                            PlaybookSize(label: "Shoes", value: "9"), PlaybookSize(label: "Socks", value: "L")
                        ], note: "Everlane tees run small, take L. Suit trousers hemmed to 30.5\"."))
            }
            let entries = [
                PlaybookEntry(
                    area: "Clothes", kind: .pick, title: "Plain tee", detail: "Uniqlo Supima Cotton crew, white and black",
                    source: "uniqlo.com", size: "M", notes: "Wash cold, hang dry, or it shrinks."),
                PlaybookEntry(
                    area: "Clothes", kind: .pick, title: "Jeans", detail: "Levi's 511 Slim, dark rinse", size: "31 × 32",
                    notes: "The 512 tapers too much."),
                PlaybookEntry(
                    area: "Clothes", kind: .pick, title: "Everyday socks", detail: "Bombas ankle, black", size: "L",
                    notes: "Replace them all at once so they match."),
                PlaybookEntry(
                    area: "Hair", kind: .routine, title: "Shower",
                    steps: [
                        PlaybookStep(text: "Shampoo, a small amount, scalp only", weekdays: [0, 3]),
                        PlaybookStep(text: "Conditioner, ends only, 2 minutes"),
                        PlaybookStep(text: "Rinse cool")
                    ]),
                PlaybookEntry(
                    area: "Hair", kind: .pick, title: "Haircut", detail: "#2 sides, scissor top, keep length at the front",
                    repeatEveryDays: 28, lastDone: Day(ordinal: today.ordinal - 20)),
                PlaybookEntry(
                    area: "Grooming", kind: .pick, title: "Nails", detail: "Straight across, file the corners",
                    repeatEveryDays: 10, lastDone: Day(ordinal: today.ordinal - 9)),
                PlaybookEntry(
                    area: "Fitness", kind: .routine, title: "Workout split",
                    notes: "Three sets of 8 to 10; add weight once all three reach 10.",
                    steps: [
                        PlaybookStep(text: "Push: bench, overhead press, dips", weekdays: [0]),
                        PlaybookStep(text: "Pull: rows, pull-ups, curls", weekdays: [2]),
                        PlaybookStep(text: "Legs: squats, Romanian deadlifts, calves", weekdays: [4])
                    ]),
                PlaybookEntry(
                    area: "Fitness", kind: .pick, title: "Running shoes", detail: "Brooks Ghost", size: "9",
                    notes: "Replace around 400 miles."),
                PlaybookEntry(area: "Grooming", kind: .pick, title: "Deodorant", detail: "Native, unscented", source: "Pharmacy")
            ]
            for entry in entries where !existing.contains(entry.title) { try? store.save(entry) }
        }

        private static func seedGoals(_ context: ModelContext) {
            guard (try? context.fetchCount(FetchDescriptor<GoalRecord>())) == 0,
                let accounts = try? CompassStore(context: context).accounts(), !accounts.isEmpty
            else { return }
            let today = Day(.now, in: .current)
            let store = CompassStore(context: context)
            let savings = accounts.first { $0.name == "High-Yield Savings" }
            let invested = Set(accounts.filter { [.taxable, .retirement].contains($0.accountClass) }.map(\.id))
            let goals = [
                Goal(name: "$100K net worth", kind: .netWorth, target: 100_000),
                Goal(
                    name: "$175K net worth", kind: .netWorth, target: 175_000, targetDate: today.addingMonths(18),
                    reward: Reward(name: "Tudor Black Bay 54", cost: 4_200)),
                Goal(name: "Emergency fund", kind: .accountTotal(savings.map { [$0.id] } ?? []), target: 30_000, targetMin: 25_000),
                Goal(name: "$50K invested", kind: .accountTotal(invested), target: 50_000),
                Goal(name: "Financial independence", kind: .fire(annualSpending: 40_000, multiplier: 25), target: 0)
            ]
            for goal in goals { try? store.save(goal) }
            try? store.refreshGoals(today: today)
        }

        private static func seed(_ context: ModelContext) {
            guard (try? context.fetchCount(FetchDescriptor<AccountRecord>())) == 0 else { return }
            let today = Day(.now, in: .current)
            let names: [(String, String?, AccountClass, BalanceSource)] = [
                ("Everyday Checking", "Example Bank", .cash, .simplefin),
                ("High-Yield Savings", "Example Bank", .cash, .simplefin),
                ("Brokerage", "Example Investments", .taxable, .simplefin),
                ("401(k)", "Example Retirement", .retirement, .simplefin),
                ("Watch collection", nil, .otherAssets, .manual)
            ]
            let snapshots = SyntheticData.dailySnapshots(accounts: names.count, years: 3, endingOn: today)
            let generatedIDs = snapshots.reduce(into: [UUID]()) { ids, snapshot in
                if ids.last != snapshot.accountID { ids.append(snapshot.accountID) }
            }
            var accountFor: [UUID: UUID] = [:]
            for (index, (name, institution, accountClass, source)) in names.enumerated() {
                let account = Account(
                    name: name, institution: institution, accountClass: accountClass,
                    source: source, externalID: source == .simplefin ? "SEED-\(index)" : nil)
                context.insert(AccountRecord(account))
                accountFor[generatedIDs[index]] = account.id
            }
            for snapshot in snapshots {
                guard let id = accountFor[snapshot.accountID] else { continue }
                let source = names[generatedIDs.firstIndex(of: snapshot.accountID)!].3
                context.insert(
                    SnapshotRecord(
                        BalanceSnapshot(
                            accountID: id, day: snapshot.day, source: source, balance: abs(snapshot.balance)
                        )))
            }
            try? context.save()
        }
    }
#endif

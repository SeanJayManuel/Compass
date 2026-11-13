#if DEBUG
    import AppKit
    import Core
    import Foundation
    import SwiftData

    /// Runs M1's data path inside the real (sandboxed) app, without the UI:
    /// SwiftData, the Keychain, SyncService and a relaunch. Debug builds only.
    ///
    ///     Compass --sandbox --self-check <SimpleFIN demo setup token>
    ///
    /// Uses a throwaway store and Keychain entry, prints PASS/FAIL lines, and quits.
    enum SelfCheck {
        static func runIfRequested() {
            let arguments = CommandLine.arguments
            if DataEnvironment.current == .sandbox, arguments.contains("--self-check-store") {
                Task { @MainActor in
                    let failures = runStoreOnly()
                    log(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
                    exit(failures == 0 ? 0 : 1)
                }
                return
            }
            guard DataEnvironment.current == .sandbox,
                let flag = arguments.firstIndex(of: "--self-check"),
                arguments.indices.contains(flag + 1)
            else { return }
            let token = arguments[flag + 1]
            Task { @MainActor in
                let failures = await run(setupToken: token)
                log(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
                exit(failures == 0 ? 0 : 1)
            }
        }

        private static func run(setupToken: String) async -> Int {
            var failures = 0
            func check(_ name: String, _ ok: Bool, _ detail: String = "") {
                log("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
                if !ok { failures += 1 }
            }

            let folder = URL.temporaryDirectory.appending(path: "CompassSelfCheck-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let storeURL = folder.appending(path: "SelfCheck.store")
            let keychain = Keychain(account: "simplefin-access-url.self-check")
            defer {
                keychain.delete()
                try? FileManager.default.removeItem(at: folder)
            }
            let today = Day(.now, in: .current)

            func netWorth(_ context: ModelContext) -> Decimal? {
                let snapshots = (try? CompassStore(context: context).snapshots()) ?? []
                return NetWorthSeries.daily(snapshots: snapshots, through: today).last?.total
            }

            do {
                let container = try CompassStore.container(at: storeURL)
                let context = container.mainContext
                let store = CompassStore(context: context)

                // Checklist 3
                try store.addManualAccount(name: "Manual", accountClass: .cash, balance: 1000, on: today)
                check("manual account at $1,000 gives net worth $1,000", netWorth(context) == 1000, "\(netWorth(context) ?? -1)")

                // Checklist 4
                let sync = SyncService(context: context, keychain: keychain)
                await sync.connect(setupToken: setupToken)
                check("connect succeeds", sync.lastError == nil, sync.lastError ?? "")
                check("access URL saved in the Keychain", keychain.exists())
                let accounts = try store.accounts()
                let synced: [Account] = accounts.filter { $0.source == BalanceSource.simplefin }
                let syncedIDs = Set(synced.map(\.id))
                var syncedTotal: Decimal = 0
                for snapshot in try store.snapshots() where syncedIDs.contains(snapshot.accountID) {
                    syncedTotal += snapshot.balance
                }
                check("demo accounts appear", !synced.isEmpty, "\(synced.count) accounts")
                check(
                    "net worth = demo sum + $1,000", netWorth(context) == syncedTotal + 1000,
                    "\(netWorth(context) ?? -1) vs \(syncedTotal + 1000)")

                // Checklist 5
                let before = (accounts.count, try store.snapshots().count)
                await sync.sync()
                let after = (try store.accounts().count, try store.snapshots().count)
                check("second sync succeeds", sync.lastError == nil, sync.lastError ?? "")
                check("second sync duplicates nothing", before == after, "\(before) -> \(after)")

                // Checklist 6
                let offline = SyncService(
                    context: context, keychain: keychain,
                    client: SimpleFINClient(transport: { _ in throw URLError(.notConnectedToInternet) })
                )
                await offline.sync()
                check(
                    "offline sync shows a clear error", offline.lastError == SimpleFINClient.Failure.offline.errorDescription,
                    offline.lastError ?? "no error")
                check("offline sync leaves data alone", (try store.snapshots().count) == after.1)
                let expected = netWorth(context)

                // Checklist 7 (data half): a fresh container on the same file
                // Keep the container alive: a context whose container is gone traps.
                let reopenedContainer = try CompassStore.container(at: storeURL)
                let reopened = reopenedContainer.mainContext
                check(
                    "data survives reopening the store", netWorth(reopened) == expected,
                    "\(netWorth(reopened) ?? -1)")
                let runs = try reopened.fetch(FetchDescriptor<SyncRunRecord>())
                check(
                    "every sync attempt is logged", runs.count == 3 && runs.filter { $0.succeeded }.count == 2,
                    "\(runs.count) runs")
            } catch {
                check("no unexpected error", false, "\(error)")
            }
            // Each group reports through check, which does the counting, so a
            // failure is counted once and always has a FAIL line saying what.
            await runAccountChecks(in: folder, check: check)
            await runSpendingChecks(in: folder, check: check)
            await runBudgetChecks(in: folder, check: check)
            runRewardPhotoCheck(in: folder, check: check)
            runLifeCheck(in: folder, check: check)
            runBackupCheck(in: folder, check: check)
            await runLinkedCheck(in: folder, check: check)
            runStoreGuardCheck(in: folder, check: check)
            return failures
        }

        /// Only the store checks, which need no SimpleFIN token:
        ///
        ///     Compass --sandbox --self-check-store
        private static func runStoreOnly() -> Int {
            var failures = 0
            let folder = URL.temporaryDirectory.appending(path: "CompassSelfCheck-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            runStoreGuardCheck(in: folder) { name, ok, detail in
                log("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
                if !ok { failures += 1 }
            }
            return failures
        }

        /// The Playbook survives a migration to a schema with more models, and a
        /// build missing one of the store's models refuses it and leaves it alone.
        private static func runStoreGuardCheck(in folder: URL, check: (String, Bool, String) -> Void) {
            let url = folder.appending(path: "Migration.store")
            let entry = PlaybookEntry(area: "Clothes", kind: .pick, title: "Plain tee", source: "example.com", size: "S")
            let sizes = PlaybookSizes(rows: [PlaybookSize(label: "Jeans", value: "31 × 31")], note: "Runs large")
            func playbook() throws -> ([PlaybookEntry], PlaybookSizes) {
                let container = try CompassStore.container(at: url)
                let store = CompassStore(context: container.mainContext)
                return (try store.playbook(), try store.playbookSizes())
            }
            do {
                do {
                    // An older build, before pay.
                    let older = CompassStore.models.without(PaystubRecord.self, PayProfileRecord.self)
                    let container = try CompassStore.container(at: url, models: older)
                    let store = CompassStore(context: container.mainContext)
                    try store.save(entry)
                    try store.save(sizes)
                }
                let (entries, kept) = try playbook()
                check(
                    "the Playbook survives a migration that adds models",
                    entries.map(\.title) == ["Plain tee"] && kept == sizes, "\(entries.count) entries")
                check("a store from this build opens again", (try? playbook()) != nil, "")

                let beforePlaybook = CompassStore.models.without(PlaybookEntryRecord.self, PlaybookSizesRecord.self)
                var refused: [String] = []
                do {
                    _ = try CompassStore.container(at: url, models: beforePlaybook)
                } catch let error as CompassStore.Refused {
                    refused = error.unknown
                }
                check(
                    "a build from before the Playbook refuses the store",
                    refused == ["PlaybookEntryRecord", "PlaybookSizesRecord"], refused.joined(separator: ", "))
                let (after, keptAfter) = try playbook()
                check(
                    "refusing leaves the Playbook in the store", after.map(\.title) == ["Plain tee"] && keptAfter == sizes,
                    "\(after.count) entries")
            } catch {
                check("no unexpected error in store guard check", false, "\(error)")
            }
        }

        /// M3: Monarch import and pins, against a fake Bridge so the pin's day is known.
        private static func runAccountChecks(in folder: URL, check: (String, Bool, String) -> Void) async {
            let today = Day(.now, in: .current)
            do {
                let container = try CompassStore.container(at: folder.appending(path: "Accounts.store"))
                let context = container.mainContext
                let store = CompassStore(context: context)

                let csv = "Date,Balance,Account\n2026-01-01,\"$1,000.00\",Everyday Checking\n2026-01-02,1100,Everyday Checking\n2026-01-02,(250),Visa Card\n"
                let plan = MonarchBalanceImport.plan(try MonarchBalanceImport.parse(csv, fileName: "x.csv"), existing: try store.accounts())
                try store.apply(plan)
                check("Monarch import creates accounts", try store.accounts().count == 2, "")
                check("imported debt is negative", try store.snapshots().contains { $0.balance == -250 }, "")
                let replan = MonarchBalanceImport.plan(try MonarchBalanceImport.parse(csv, fileName: "x.csv"), existing: try store.accounts())
                try store.apply(replan)
                check(
                    "re-importing duplicates nothing", try store.snapshots().count == 3 && replan.newAccounts.isEmpty,
                    "\(try store.snapshots().count) snapshots")

                // A synced account the fake Bridge reports at $1,200 today.
                func bridge(_ balance: String) -> SimpleFINClient {
                    let body =
                        #"{"errlist":[],"connections":[],"accounts":[{"id":"ACT-1","name":"Synced","conn_id":"C","currency":"USD","balance":"\#(balance)","balance-date":\#(Int(today.startDate(in: .current).timeIntervalSince1970) + 3600)}]}"#
                    return SimpleFINClient(transport: { request in
                        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                    })
                }
                let keychain = Keychain(account: "simplefin-access-url.self-check-accounts")
                defer { keychain.delete() }
                try keychain.write("https://user:pass@bridge.invalid/simplefin")

                await SyncService(context: context, keychain: keychain, client: bridge("1200")).sync()
                guard let synced = try store.accounts().first(where: { $0.source == .simplefin }) else {
                    check("sync creates the synced account", false, "")
                    return
                }
                try store.logBalance(1000, for: synced, on: today)
                await SyncService(context: context, keychain: keychain, client: bridge("1200")).sync()
                let afterFarSync = Staleness.latest(snapshots: try store.snapshots())[synced.id]
                check(
                    "a pin survives a same-day sync", afterFarSync?.source == .manual && afterFarSync?.balance == 1000,
                    "\(String(describing: afterFarSync))")

                await SyncService(context: context, keychain: keychain, client: bridge("1005")).sync()
                let afterCloseSync = Staleness.latest(snapshots: try store.snapshots())[synced.id]
                check(
                    "a sync within 1% clears the pin", afterCloseSync?.source == .simplefin && afterCloseSync?.balance == 1005,
                    "\(String(describing: afterCloseSync))")
            } catch {
                check("no unexpected error in account checks", false, "\(error)")
            }
        }

        /// M5: transaction import, filing and transactions arriving by sync.
        private static func runSpendingChecks(in folder: URL, check: (String, Bool, String) -> Void) async {
            let today = Day(.now, in: .current)
            do {
                let container = try CompassStore.container(at: folder.appending(path: "Spending.store"))
                let context = container.mainContext
                let store = CompassStore(context: context)

                let header = "Date,Merchant,Category,Account,Original Statement,Notes,Amount,Tags,Owner,Reviewed,Id"
                let csv = [
                    header,
                    "2026-09-02,Chipotle,Restaurants,Card,CHIPOTLE 0412,,-12.40,,Alex,,1",
                    "2026-09-03,Payroll,Paychecks,Checking,ACME,,5000,,Alex,,2",
                    "2026-09-04,Card Payment,Credit Card Payment,Checking,PAYMENT,,-900,,Alex,,3",
                    "2026-09-05,Mystery Shop,,Card,MYSTERY,,-20,,Alex,,4"
                ].joined(separator: "\r\n")
                let rows = try MonarchTransactionImport.parse(csv)
                try store.apply(MonarchTransactionImport.plan(rows, existing: try store.accounts(), knownExternalIDs: try store.knownExternalIDs()))
                check("transaction import stores every row", try store.transactions().count == 4, "\(try store.transactions().count)")
                let again = MonarchTransactionImport.plan(rows, existing: try store.accounts(), knownExternalIDs: try store.knownExternalIDs())
                check("re-importing transactions adds nothing", again.transactions.isEmpty, "\(again.transactions.count)")
                check("import learns merchant rules", try store.rules().category(for: "Chipotle") == "Restaurants", "")

                let report = Spending.month(Month(year: 2026, month: 9), transactions: try store.transactions(), kinds: try store.kinds())
                check(
                    "spending leaves out income and transfers", report.map(\.category).sorted() == ["Restaurants", "Uncategorized"],
                    "\(report.map(\.category))")

                let mystery = try store.transactions().first { $0.merchant == "Mystery Shop" }!
                try store.file(mystery, as: "Shopping")
                check("filing sets the merchant's rule", try store.rules().category(for: "MYSTERY SHOP") == "Shopping", "")

                // Transactions by sync, from a fake Bridge, twice.
                let posted = Int(today.startDate(in: .current).timeIntervalSince1970) + 3600
                let body =
                    #"{"errlist":[],"connections":[],"accounts":[{"id":"ACT-9","name":"Synced card","conn_id":"C","currency":"USD","balance":"-50","balance-date":\#(posted),"transactions":[{"id":"T-1","posted":\#(posted),"amount":"-8.75","description":"MYSTERY SHOP 1234","payee":"Mystery Shop"},{"id":"T-2","posted":0,"amount":"-3","description":"PENDING","pending":true}]}]}"#
                let client = SimpleFINClient(transport: { request in
                    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
                let keychain = Keychain(account: "simplefin-access-url.self-check-spending")
                defer { keychain.delete() }
                try keychain.write("https://user:pass@bridge.invalid/simplefin")
                await SyncService(context: context, keychain: keychain, client: client).sync()
                await SyncService(context: context, keychain: keychain, client: client).sync()
                let synced = try store.transactions().filter { $0.externalID.hasPrefix("simplefin:") }
                check("synced transactions arrive once, pending left out", synced.count == 1, "\(synced.count)")
                check("synced transactions are filed by the rules", synced.first?.category == "Shopping", "\(String(describing: synced.first?.category))")

                // Monarch's "Card" is SimpleFIN's "Synced card": import today's purchase,
                // merge the accounts, and the purchase should be there once.
                let iso = today.startDate(in: .current).formatted(.iso8601.year().month().day())
                let overlap = "\(header)\r\n\(iso),Mystery Shop,Shopping,Card,MYSTERY,,-8.75,,Alex,,5"
                try store.apply(
                    MonarchTransactionImport.plan(
                        try MonarchTransactionImport.parse(overlap),
                        existing: try store.accounts(), knownExternalIDs: try store.knownExternalIDs()))
                let card = try store.accounts().first { $0.name == "Card" }!
                let syncedCard = try store.accounts().first { $0.name == "Synced card" }!
                try store.merge(card, into: syncedCard)
                let copies = try store.transactions().filter { $0.amount == Decimal(string: "-8.75")! }
                check("merging removes the source account", try !store.accounts().contains { $0.id == card.id }, "")
                check(
                    "a purchase from both Monarch and SimpleFIN is kept once", copies.count == 1 && copies.first!.externalID.hasPrefix("simplefin:"),
                    "\(copies.map(\.externalID))")
                check("merged transactions move to the target", try store.transactions().filter { $0.accountID == card.id }.isEmpty, "")

                // One holding SimpleFIN reports twice ("Manage" and "View" ESPP):
                // once merged, the next sync neither adds it back nor counts it.
                let viewFeed = SimpleFINAccount(id: "self-check-view", name: "View ESPP", institution: nil, balance: 100, balanceDate: .now)
                try store.apply(SyncMerge.plan(fetched: [viewFeed], existing: try store.accounts(), timeZone: .current))
                let view = try store.accounts().first { $0.externalID == viewFeed.id }!
                try store.merge(view, into: try store.accounts().first { $0.id == syncedCard.id }!)
                let resync = SyncMerge.plan(fetched: [viewFeed], existing: try store.accounts(), timeZone: .current)
                check(
                    "a merged SimpleFIN account isn't added back by the next sync",
                    resync.newAccounts.isEmpty && resync.snapshots.isEmpty, "\(resync.newAccounts.count) added")
            } catch {
                check("no unexpected error in spending checks", false, "\(error)")
            }
        }

        /// Transfers between their own accounts found after a sync, the budget
        /// sheet's numbers, refiling a charge, and a category rename carrying its
        /// rules, kind and plan, on a small store and a fake Bridge.
        private static func runBudgetChecks(in folder: URL, check: (String, Bool, String) -> Void) async {
            let today = Day(.now, in: .current)
            do {
                let container = try CompassStore.container(at: folder.appending(path: "Budget.store"))
                let context = container.mainContext
                let store = CompassStore(context: context)

                // A card payment and a move into savings, uncategorized as SimpleFIN
                // sends them, and one purchase. No payee has a rule yet.
                let posted = Int(today.startDate(in: .current).timeIntervalSince1970) + 3600
                func remote(_ id: String, _ payee: String, _ amount: String) -> String {
                    #"{"id":"\#(id)","posted":\#(posted),"amount":"\#(amount)","description":"\#(payee.uppercased())","payee":"\#(payee)"}"#
                }
                func account(_ id: String, _ name: String, _ balance: String, _ transactions: [String]) -> String {
                    #"{"id":"\#(id)","name":"\#(name)","conn_id":"C","currency":"USD","balance":"\#(balance)","balance-date":\#(posted),"transactions":[\#(transactions.joined(separator: ","))]}"#
                }
                let accounts = [
                    account("CHK", "Checking", "4000", [remote("C-1", "Card Autopay", "-700.00"), remote("C-2", "Online Transfer", "-1000")]),
                    account("CRD", "Card", "-300", [remote("K-1", "Payment Thank You", "700"), remote("K-2", "Corner Bistro", "-42.50")]),
                    account("SAV", "Savings", "9000", [remote("S-1", "Transfer From Checking", "1000.00")])
                ]
                let body = #"{"errlist":[],"connections":[],"accounts":["# + accounts.joined(separator: ",") + "]}"
                let client = SimpleFINClient(transport: { request in
                    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
                let keychain = Keychain(account: "simplefin-access-url.self-check-budget")
                defer { keychain.delete() }
                try keychain.write("https://user:pass@bridge.invalid/simplefin")

                await SyncService(context: context, keychain: keychain, client: client).sync()
                let synced = try store.transactions()
                let transfers = synced.filter { $0.category == TransferMatch.category }
                check(
                    "a sync files money moving between their accounts under Transfer",
                    transfers.count == 4 && synced.first { $0.merchant == "Corner Bistro" }?.category == nil,
                    "\(transfers.count) of \(synced.count) filed")
                check("filing transfers learns no merchant rule", try store.rules().all.isEmpty, "\(try store.rules().all.count) rules")
                await SyncService(context: context, keychain: keychain, client: client).sync()
                let refound = try store.fileTransfers()
                check(
                    "a second sync and Find transfers file nothing new",
                    try store.transactions().count == synced.count && refound == 0, "\(refound) filed again")

                // The budget sheet: pay against plan, rent paid, a stock buy left out.
                guard let checking = try store.accounts().first(where: { $0.name == "Checking" }) else {
                    check("the sync creates the checking account", false, "")
                    return
                }
                func local(_ merchant: String, _ category: String, _ amount: Decimal, daysAgo: Int = 0, _ id: String) -> Transaction {
                    Transaction(
                        accountID: checking.id, day: Day(ordinal: today.ordinal - daysAgo), amount: amount,
                        merchant: merchant, category: category, externalID: "check:\(id)")
                }
                try store.insert([
                    local("Payroll", "Paychecks", 5000, "pay"), local("Landlord", "Rent", -2100, "rent"),
                    local("Brokerage", "Buy", -1000, "buy")
                ])
                try context.save()
                try store.save(BudgetSchedule(BudgetPlan(flexibleBudget: 500, expected: ["Rent": 2100, "Internet": 70], plannedIncome: ["Paychecks": 5200])))
                let sheet = FlexBudget.sheet(
                    Month(today), transactions: try store.transactions(), kinds: try store.kinds(),
                    plan: try store.budgetPlan(for: Month(today)))
                let bistro = Decimal(string: "42.50")!
                check(
                    "the budget sheet sets income against fixed bills and flexible spending",
                    sheet.income.actual == 5000 && sheet.income.planned == 5200 && sheet.fixed.actual == 2100
                        && sheet.fixed.planned == 2170 && sheet.flexible.actual == bistro && sheet.actualNet == 5000 - 2100 - bistro,
                    "income \(sheet.income.actual), fixed \(sheet.fixed.actual), flexible \(sheet.flexible.actual)")
                check("the fixed plan is the emergency-fund basis", sheet.emergencyFund.sixMonths == 13_020, "\(sheet.emergencyFund.sixMonths)")

                // An example: an Anthropic charge in Miscellaneous moves to a
                // new Software category, and last month's goes with it.
                try store.insert([
                    local("Anthropic", "Miscellaneous", -20, "ai-now"), local("Anthropic", "Miscellaneous", -20, daysAgo: 31, "ai-before"),
                    local("Hardware Co", "Miscellaneous", -15, "misc")
                ])
                try context.save()
                guard let anthropic = try store.transactions().first(where: { $0.externalID == "check:ai-now" }) else {
                    check("the Anthropic charge is stored", false, "")
                    return
                }
                try store.file(anthropic, as: "Software")
                let others = try store.sameMerchant(as: anthropic, in: "Miscellaneous")
                try store.refileSameMerchant(as: anthropic, from: "Miscellaneous", to: "Software")
                let afterMove = try store.transactions()
                let rule = try store.rules().category(for: "ANTHROPIC")
                check(
                    "moving a charge to a new category offers the merchant's others and sets its rule",
                    others == 1 && afterMove.filter { $0.merchant == "Anthropic" }.allSatisfy { $0.category == "Software" }
                        && afterMove.first { $0.merchant == "Hardware Co" }?.category == "Miscellaneous" && rule == "Software",
                    "\(others) others")

                // A rename carries transactions, rules and the plan; a guessed kind too.
                try store.save(
                    store.budgetSchedule().changing(Month(today), .onward) {
                        $0.expected["Software"] = 20
                        $0.roles["Software"] = .fixed
                    })
                try store.renameCategory("Software", to: "Apps")
                try store.renameCategory("Paychecks", to: "Day Job")
                let renamed = try store.budgetPlan(for: Month(today))
                let kinds = try store.kinds()
                let apps = try store.transactions().filter { $0.category == "Apps" }.count
                let renamedRule = try store.rules().category(for: "Anthropic")
                check(
                    "a rename carries transactions, merchant rules and the budget plan",
                    apps == 2 && renamedRule == "Apps" && renamed.expected["Apps"] == 20 && renamed.role(of: "Apps") == .fixed
                        && renamed.expected["Software"] == nil,
                    "\(renamed.expected)")
                check(
                    "a rename keeps a kind that came from the old name",
                    kinds["Day Job"] == .income && renamed.plannedIncome == ["Day Job": 5200], "\(kinds)")

                // Merging Miscellaneous into Apps: Apps keeps its own role.
                try store.renameCategory("Miscellaneous", to: "Apps")
                let merged = try store.transactions()
                let mergedRole = try store.budgetPlan(for: Month(today)).role(of: "Apps")
                check(
                    "a merge folds one category into another",
                    !merged.contains { $0.category == "Miscellaneous" } && merged.filter { $0.category == "Apps" }.count == 3
                        && mergedRole == .fixed, "")
            } catch {
                check("no unexpected error in budget checks", false, "\(error)")
            }
        }

        /// A claimed reward's photo is downscaled, stored and survives reopening.
        private static func runRewardPhotoCheck(in folder: URL, check: (String, Bool, String) -> Void) {
            do {
                let url = folder.appending(path: "Rewards.store")
                var goal = Goal(
                    name: "$100K", kind: .netWorth, target: 100_000,
                    status: .achieved(on: Day(.now, in: .current), value: 100_000), reward: Reward(name: "Watch"))
                goal.reward?.claimedOn = Day(.now, in: .current)
                let photo = NSImage(size: NSSize(width: 3000, height: 2000), flipped: false) { rect in
                    NSColor.systemTeal.setFill(); rect.fill(); return true
                }
                let jpeg = RewardPhoto.jpeg(from: photo)
                do {
                    let container = try CompassStore.container(at: url)
                    try CompassStore(context: container.mainContext).save(goal)
                    try CompassStore(context: container.mainContext).record(for: goal.id)?.rewardPhoto = jpeg
                    try container.mainContext.save()
                }
                let reopened = try CompassStore.container(at: url)
                let stored = try CompassStore(context: reopened.mainContext).record(for: goal.id)?.rewardPhoto
                let size = stored.flatMap(NSImage.init(data:)).flatMap { $0.representations.first }.map { max($0.pixelsWide, $0.pixelsHigh) }
                check("a reward photo is stored downscaled and survives reopening", size == 1024, "longest side \(size ?? -1)")
            } catch {
                check("no unexpected error in reward photo check", false, "\(error)")
            }
        }

        /// Life goals (kept for the backup), the vision, habits and money links survive the store.
        private static func runLifeCheck(in folder: URL, check: (String, Bool, String) -> Void) {
            do {
                let url = folder.appending(path: "Life.store")
                let quarter = Quarter(year: 2026, quarter: 3)
                let goal = LifeGoal(title: "Swim", period: .quarter(quarter), progress: .count(current: 4, target: 10))
                do {
                    let container = try CompassStore.container(at: url)
                    let store = CompassStore(context: container.mainContext)
                    try store.save(goal)
                    let (original, copy) = LifeGoals.carryOver(goal)
                    try store.save(original)
                    try store.save(copy)
                    try store.saveVision("Calm")
                    let gym = Habit(title: "Gym", perWeek: 4, startedOn: Day(year: 2026, month: 7, day: 1))
                    try store.save(Habits.toggle(gym, on: Day(year: 2026, month: 7, day: 2)))
                    try store.save(ReminderMeasure(reminderID: "r", title: "$50k net worth", measure: .netWorth, target: 50_000))
                }
                let reopenedContainer = try CompassStore.container(at: url)
                let reopened = reopenedContainer.mainContext
                let goals = try reopened.fetch(FetchDescriptor<LifeGoalRecord>()).compactMap(\.goal)
                check(
                    "life goals survive the store, carry-over keeps the original",
                    goals.filter { $0.title == "Swim" }.count == 2 && goals.contains { $0.status == .carriedOver(to: quarter.next) },
                    "\(goals.count) goals")
                let store = CompassStore(context: reopened)
                let vision = try store.vision()
                let links = try store.reminderMeasures()
                check(
                    "the vision and a quarter reminder's money link survive the store",
                    vision == "Calm" && links.first?.target == 50_000, "\(links.count) links")
                let habits = try store.habits()
                check(
                    "habits and their check-ins survive the store",
                    habits.first { $0.title == "Gym" }?.checkIns == [Day(year: 2026, month: 7, day: 2)], "\(habits.count) habits")
            } catch {
                check("no unexpected error in life check", false, "\(error)")
            }
        }

        /// A backup folder holds the bundle and both CSVs, and the bundle reads
        /// back with exact amounts.
        private static func runBackupCheck(in folder: URL, check: (String, Bool, String) -> Void) {
            do {
                let container = try CompassStore.container(at: folder.appending(path: "Backup.store"))
                let store = CompassStore(context: container.mainContext)
                try store.addManualAccount(
                    name: "Cash, jar", accountClass: .cash, balance: Decimal(string: "0.10")!,
                    on: Day(year: 2026, month: 10, day: 1))
                let exports = folder.appending(path: "Exports")
                try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
                let saved = try store.exportBackup(into: exports)
                let second = try store.exportBackup(into: exports)
                let bundle = try Backup.decode(try Data(contentsOf: saved.appending(path: "compass-backup.json")))
                let balances = try String(contentsOf: saved.appending(path: "balances.csv"), encoding: .utf8)
                check(
                    "a backup reads back with exact amounts",
                    bundle.accounts.count == 1 && bundle.snapshots.first?.balance == Decimal(string: "0.10")!, "")
                check(
                    "a backup writes balances and transactions as CSVs",
                    balances.contains("\"Cash, jar\"") && balances.contains("0.10")
                        && FileManager.default.fileExists(atPath: saved.appending(path: "transactions.csv").path), "")
                check("a second backup the same day gets its own folder", second != saved, second.lastPathComponent)
            } catch {
                check("no unexpected error in backup check", false, "\(error)")
            }
        }

        /// A life goal following net worth is marked done once net worth reaches it.
        private static func runLinkedCheck(in folder: URL, check: (String, Bool, String) -> Void) async {
            do {
                let url = folder.appending(path: "Linked.store")
                let container = try CompassStore.container(at: url)
                let store = CompassStore(context: container.mainContext)
                let today = Day(.now, in: .current)
                try store.addManualAccount(name: "Savings", accountClass: .cash, balance: 1000, on: today)
                let goal = LifeGoal(title: "Save $500", period: .year(today.year), progress: .linked(.netWorth, target: 500))
                try store.save(goal)
                let cache = NetWorthCache(container: container, storeURL: url)
                cache.refresh()
                for _ in 0..<50 where cache.breakdown.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
                let status = try store.lifeGoals().first { $0.id == goal.id }?.status
                check("a life goal following net worth is done once it's reached", status == .done(on: today), "\(String(describing: status))")
            } catch {
                check("no unexpected error in linked check", false, "\(error)")
            }
        }

        private static func log(_ line: String) {
            FileHandle.standardError.write(Data("[self-check] \(line)\n".utf8))
        }
    }
    private extension Array where Element == any PersistentModel.Type {
        func without(_ models: any PersistentModel.Type...) -> Self {
            let out = Set(models.map(ObjectIdentifier.init))
            return filter { !out.contains(ObjectIdentifier($0)) }
        }
    }
#endif

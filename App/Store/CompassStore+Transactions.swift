import Core
import Foundation
import SwiftData

extension CompassStore {
    func transactions() throws -> [Transaction] {
        try context.fetch(FetchDescriptor<TransactionRecord>()).map(\.transaction)
    }

    func transaction(_ id: UUID) throws -> Transaction? {
        var one = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.id == id })
        one.fetchLimit = 1
        return try context.fetch(one).first?.transaction
    }

    /// Saves a transaction's note, flags, category, split and the goal that
    /// paid for it; nothing else
    /// about it changes. Filing all of it one way takes a split off.
    func save(_ edit: TransactionEdit, for id: UUID) throws {
        var one = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.id == id })
        one.fetchLimit = 1
        guard let record = try context.fetch(one).first else { return }
        let edit = edit.saving(over: TransactionEdit(record.transaction))
        // Goals' progress reads what they paid for; other edits leave it alone.
        let touchesGoal = record.paidFromGoal != nil || edit.paidFromGoal != nil
        record.category = edit.category
        record.splits = edit.splits
        record.note = edit.note
        record.oneOff = edit.oneOff
        record.reimbursable = edit.reimbursable
        record.reimbursableAmount = edit.reimbursable ? edit.reimbursableAmount : nil
        record.paidFromGoal = edit.paidFromGoal
        record.paidFromGoalAmount = edit.paidFromGoal == nil ? nil : edit.paidFromGoalAmount
        try context.save()
        if touchesGoal { NotificationCenter.default.post(name: .goalPaymentsChanged, object: nil) }
    }

    func knownExternalIDs() throws -> Set<String> {
        Set(try context.fetch(FetchDescriptor<TransactionRecord>()).map(\.externalID))
    }

    func rules() throws -> CategoryRules {
        CategoryRules(
            Dictionary(
                try context.fetch(FetchDescriptor<CategoryRuleRecord>()).map { ($0.merchantKey, $0.category) },
                uniquingKeysWith: { first, _ in first }
            ))
    }

    /// The stored rules, with every merchant filed some other way (a synced
    /// copy taking its Monarch twin's category) learning from its history.
    func filingRules() throws -> CategoryRules {
        let history = try transactions()
        let kinds = try kinds()
        let transfers = Set(history.compactMap(\.category).filter { (kinds[$0] ?? CategoryKind.guess($0)) == .transfer })
        return try rules().filling(from: history, skipping: transfers)
    }

    /// Files transactions still without a category under a guess, to be
    /// confirmed in review: the merchant's rule, a known merchant in its name
    /// or bank text, or a common merchant word. One that reads like a move
    /// between accounts stays unfiled for the transfer suggestions.
    func guessOpenCategories() throws {
        let rules = try filingRules()
        let categories = try knownCategories()
        let oneSided = TransferMatch.likelyOneSided(in: try transactions(), kinds: try kinds())
        let open = try context.fetch(FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.category == nil }))
        for record in open where !oneSided.contains(record.id) {
            guard let guess = CategoryGuess.category(for: record.transaction, rules: rules, categories: categories) else { continue }
            record.category = guess
            // A guess is never filed without them seeing it.
            record.reviewPending = true
        }
        try context.save()
    }

    /// They agree with these transactions' categories.
    func confirm(_ ids: some Sequence<UUID>) throws {
        let ids = Set(ids)
        let pending = try context.fetch(FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.reviewPending == true }))
        for record in pending where ids.contains(record.id) { record.reviewPending = nil }
        try context.save()
    }

    func kinds() throws -> [String: CategoryKind] {
        Dictionary(
            try context.fetch(FetchDescriptor<CategoryKindRecord>()).compactMap { record in
                CategoryKind(rawValue: record.kindRaw).map { (record.category, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Imports transactions and learns a rule for each merchant that has none.
    func apply(_ plan: TransactionImportPlan) throws {
        for account in plan.newAccounts { context.insert(AccountRecord(account)) }
        for transaction in plan.transactions { context.insert(TransactionRecord(transaction)) }
        let existing = try rules().all
        for (merchant, category) in CategoryRules.learn(from: plan.transactions).all where existing[merchant] == nil {
            context.insert(CategoryRuleRecord(merchantKey: merchant, category: category))
        }
        try context.save()
        try removeDuplicateTransactions()
    }

    /// Keeps one copy of each purchase that arrived from both Monarch and
    /// SimpleFIN: the synced one (its ID stops the next sync re-adding it),
    /// taking the imported one's category if it has none.
    func removeDuplicateTransactions() throws {
        let records = try context.fetch(FetchDescriptor<TransactionRecord>())
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pairs = TransactionDedupe.pairs(in: records.map(\.transaction))
        guard !pairs.isEmpty else { return }
        for pair in pairs {
            guard let imported = byID[pair.imported], let synced = byID[pair.synced] else { continue }
            if synced.category == nil { synced.category = imported.category }
            // Monarch's copy was history, already looked over.
            synced.reviewPending = nil
            context.delete(imported)
        }
        try context.save()
    }

    /// The newest day of any synced transaction, where the next sync's
    /// transaction window starts from.
    func newestSyncedTransactionDay() throws -> Day? {
        var descriptor = FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.externalID.starts(with: "simplefin:") },
            sortBy: [SortDescriptor(\.dayOrdinal, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first.map { Day(ordinal: $0.dayOrdinal) }
    }

    #if DEBUG
        func insertSeed(_ transaction: Transaction) { context.insert(TransactionRecord(transaction)) }
    #endif

    /// Synced transactions wait in review; seeds and history don't.
    func insert(_ transactions: [Transaction], pendingReview: Bool = false) throws {
        for transaction in transactions {
            let record = TransactionRecord(transaction)
            if pendingReview { record.reviewPending = true }
            context.insert(record)
        }
    }

    /// Files one transaction. Under a spending or income category it also
    /// sets the merchant's rule and files the merchant's other uncategorized
    /// transactions the same way. A transfer files only this one: moving
    /// money is about the occasion, not the merchant, so one Venmo cash-out
    /// never makes every Venmo charge a transfer. Returns whether the
    /// merchant's rule was set.
    @discardableResult
    func file(_ transaction: Transaction, as category: String) throws -> Bool {
        let id = transaction.id
        let kind = try kinds()[category] ?? CategoryKind.guess(category)
        guard kind != .transfer else {
            var one = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.id == id })
            one.fetchLimit = 1
            if let record = try context.fetch(one).first {
                record.refile(category)
                record.reviewPending = nil
            }
            try context.save()
            return false
        }
        // Money in and money out from one merchant have rules of their own.
        let key = CategoryRules.key(for: transaction)
        var rule = FetchDescriptor<CategoryRuleRecord>(predicate: #Predicate { $0.merchantKey == key })
        rule.fetchLimit = 1
        if let record = try context.fetch(rule).first {
            record.category = category
        } else {
            context.insert(CategoryRuleRecord(merchantKey: key, category: category))
        }
        // Its other unconfirmed charges were guessed the same way, so they
        // follow too, still waiting in review.
        let open = try context.fetch(
            FetchDescriptor<TransactionRecord>(
                predicate: #Predicate {
                    $0.category == nil || $0.reviewPending == true || $0.id == id
                }))
        for record in open where record.id == id || CategoryRules.key(merchant: record.merchant, incoming: record.amount > 0) == key {
            record.refile(category)
            if record.id == id { record.reviewPending = nil }
        }
        try context.save()
        return true
    }

    /// A category name as typed, matched to one already in use when only the
    /// case or spacing differs (CategoryRules.existing): "software" when
    /// Software exists files under Software, not a twin that splits the
    /// budget. A new name comes back tidied. For typed names only; it can
    /// read every transaction's category when the name is new.
    func existingCategory(matching typed: String) throws -> String {
        let name = CategoryRules.tidy(typed)
        if let match = CategoryRules.existing(name, among: try knownCategories()) { return match }
        let optional: String? = name
        var exact = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.category == optional })
        exact.fetchLimit = 1
        if try context.fetchCount(exact) > 0 { return name }
        return CategoryRules.existing(name, among: try allCategories()) ?? name
    }

    /// Files the uncategorized sides of transfers between their own accounts
    /// under Transfer (TransferMatch), from `since` on or across all history.
    /// No merchant rule is learned from them, so a merchant never becomes
    /// Transfer by this. Returns how many transactions it filed; running it
    /// again files nothing new.
    @discardableResult
    func fileTransfers(since: Day? = nil) throws -> Int {
        // A pair can span this many calendar days. History is read three
        // spans back, so a side already filed near the start still meets its
        // own partner and isn't paired with a new charge instead; only the
        // last span before `since` and later is filed.
        let span = TransferMatch.maxCalendarDays(forBusinessDays: TransferMatch.dayTolerance)
        var descriptor = FetchDescriptor<TransactionRecord>()
        if let since {
            let first = since.ordinal - 3 * span
            descriptor.predicate = #Predicate { $0.dayOrdinal >= first }
        }
        let records = try context.fetch(descriptor)
        let kinds = try kinds()
        let fileFrom = since.map { $0.ordinal - span } ?? Int.min
        let filed = TransferMatch.toFile(in: records.map(\.transaction), kinds: kinds)
            .intersection(records.filter { $0.dayOrdinal >= fileFrom }.map(\.id))
        guard !filed.isEmpty else { return 0 }
        for record in records where filed.contains(record.id) {
            record.category = TransferMatch.category
        }
        if (kinds[TransferMatch.category] ?? CategoryKind.guess(TransferMatch.category)) != .transfer {
            try setKind(.transfer, for: TransferMatch.category)
        }
        try context.save()
        return filed.count
    }

    /// How many transactions each category holds; nil is uncategorized.
    func categoryCounts() throws -> [String?: Int] {
        var descriptor = FetchDescriptor<TransactionRecord>()
        descriptor.propertiesToFetch = [\.category]
        return try context.fetch(descriptor).reduce(into: [:]) { counts, record in counts[record.category, default: 0] += 1 }
    }

    /// Renames `old` to `new` everywhere it's used: its transactions, merchant
    /// rules, kind and budget plan. A rename keeps the old kind and role, even
    /// ones that came from the old name's guess. When `new` already exists
    /// it's a merge: `new` keeps its own kind and role, and planned amounts
    /// add up.
    func renameCategory(_ old: String, to new: String) throws {
        var new = CategoryRules.tidy(new)
        // "software" when Software exists is a merge into Software, not a twin.
        var others = try allCategories()
        others.remove(old)
        if let existing = CategoryRules.existing(new, among: others) {
            new = existing
        }
        guard !new.isEmpty, new != old else { return }
        // Changing only the case renames it; it isn't a merge with itself.
        let merging = try new.caseInsensitiveCompare(old) != .orderedSame && categoryExists(new)
        let kinds = try kinds()
        let oldKind = kinds[old] ?? CategoryKind.guess(old)
        let oldName: String? = old
        for record in try context.fetch(FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.category == oldName })) {
            record.category = new
        }
        // Inside splits too, a merge adding parts together (seam 43).
        for record in try context.fetch(FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.splitsData != nil })) {
            let renamed = Splits.renaming(record.transaction, old, to: new)
            (record.category, record.splits) = (renamed.category, renamed.splits)
        }
        for record in try context.fetch(FetchDescriptor<CategoryRuleRecord>(predicate: #Predicate { $0.category == old })) {
            record.category = new
        }
        let kindRecords = try context.fetch(
            FetchDescriptor<CategoryKindRecord>(
                predicate: #Predicate {
                    $0.category == old || $0.category == new
                }))
        for record in kindRecords where record.category == old { context.delete(record) }
        if !merging, oldKind != (kinds[new] ?? CategoryKind.guess(new)) {
            if let record = kindRecords.first(where: { $0.category == new }) {
                record.kindRaw = oldKind.rawValue
            } else {
                context.insert(CategoryKindRecord(category: new, kind: oldKind))
            }
        }
        // Saving the plan saves the rest with it.
        try save(try budgetSchedule().renaming(old, to: new, into: merging))
    }

    /// Every category in use or known, for matching a typed name.
    func allCategories() throws -> Set<String> {
        try knownCategories().union(categoryCounts().keys.compactMap { $0 }).union(splitTransactions().flatMap { $0.splits.map(\.category) })
    }

    /// Whether any transaction, rule or plan already uses `name`, ignoring case.
    func categoryExists(_ name: String) throws -> Bool {
        if try knownCategories().contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return true }
        let optional: String? = name
        var transactions = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.category == optional })
        transactions.fetchLimit = 1
        var rules = FetchDescriptor<CategoryRuleRecord>(predicate: #Predicate { $0.category == name })
        rules.fetchLimit = 1
        if try context.fetchCount(transactions) > 0 || context.fetchCount(rules) > 0 || budgetSchedule().categories.contains(name) { return true }
        // Only filed transactions or split parts hold it, maybe under another case ("groceries" for Groceries).
        return CategoryRules.existing(name, among: try allCategories()) != nil
    }

    /// Every category name Compass knows: from merchant rules, kinds and the
    /// budget plan. Transfer has no rule (it's never learned), so its kind
    /// brings it in. For category menus, without reading every transaction.
    func knownCategories() throws -> Set<String> {
        Set(try context.fetch(FetchDescriptor<CategoryRuleRecord>()).map(\.category))
            .union(try context.fetch(FetchDescriptor<CategoryKindRecord>()).map(\.category))
            .union(try budgetSchedule().categories)
    }

    /// The same merchant's other transactions filed under `category`, such as
    /// last months' Anthropic charges still in Miscellaneous after this
    /// month's was moved.
    func sameMerchant(as transaction: Transaction, in category: String) throws -> Int {
        try records(sameMerchantAs: transaction, in: category).count
    }

    /// Moves the same merchant's other transactions from `old` to `new`.
    /// Returns how many moved.
    @discardableResult
    func refileSameMerchant(as transaction: Transaction, from old: String, to new: String) throws -> Int {
        let records = try records(sameMerchantAs: transaction, in: old)
        for record in records { record.refile(new) }
        try context.save()
        return records.count
    }

    private func records(sameMerchantAs transaction: Transaction, in category: String) throws -> [TransactionRecord] {
        let name: String? = category
        let id = transaction.id
        guard !Merchant.key(transaction.merchant).isEmpty else { return [] }
        // The same direction only: refiling a paycheck never moves lunches.
        let key = CategoryRules.key(for: transaction)
        var descriptor = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.category == name && $0.id != id })
        descriptor.propertiesToFetch = [\.id, \.merchant, \.category, \.amount, \.splitsData]
        // A split stays as it was made.
        return try context.fetch(descriptor).filter { $0.splitsData == nil && CategoryRules.key(merchant: $0.merchant, incoming: $0.amount > 0) == key }
    }

    // MARK: Changes Claude makes (seam 31)

    /// Sets a merchant rule by its key, or with nil removes it.
    func setRule(_ key: String, to category: String?) throws {
        var descriptor = FetchDescriptor<CategoryRuleRecord>(predicate: #Predicate { $0.merchantKey == key })
        descriptor.fetchLimit = 1
        let record = try context.fetch(descriptor).first
        switch (record, category) {
        case (let record?, let category?): record.category = category
        case (nil, let category?): context.insert(CategoryRuleRecord(merchantKey: key, category: category))
        case (let record?, nil): context.delete(record)
        case (nil, nil): break
        }
        try context.save()
    }

    /// Adds one transaction Claude was given (cash, say), filed as it is.
    func add(_ transaction: Transaction) throws {
        context.insert(TransactionRecord(transaction))
        try context.save()
    }

    func deleteTransaction(_ id: UUID) throws {
        try context.delete(model: TransactionRecord.self, where: #Predicate { $0.id == id })
        try context.save()
    }

    /// Files each transaction as given (nil leaves it unfiled).
    func setCategories(_ categories: [UUID: String?]) throws {
        guard !categories.isEmpty else { return }
        let ids = Array(categories.keys)
        for record in try context.fetch(FetchDescriptor<TransactionRecord>(predicate: #Predicate { ids.contains($0.id) })) {
            if let category = categories[record.id] { record.refile(category) }
        }
        try context.save()
    }

    func splitTransactions() throws -> [Transaction] {
        try context.fetch(FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.splitsData != nil })).map(\.transaction)
    }

    /// These transactions as they are now, by id; missing ones are gone.
    func transactions(_ ids: [UUID]) throws -> [UUID: Transaction] {
        Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<TransactionRecord>(predicate: #Predicate { ids.contains($0.id) }))
                .map { ($0.id, $0.transaction) })
    }

    /// The categories these transactions have now; missing ones are gone.
    func categories(of ids: [UUID]) throws -> [UUID: String?] {
        Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<TransactionRecord>(predicate: #Predicate { ids.contains($0.id) }))
                .map { ($0.id, $0.category) })
    }

    /// The transactions and rule keys filed as `category`, and its stored kind.
    func uses(of category: String) throws -> (transactions: [UUID], rules: [String], kind: CategoryKind?) {
        let name: String? = category
        var transactions = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.category == name })
        transactions.propertiesToFetch = [\.id]
        let rules = try context.fetch(FetchDescriptor<CategoryRuleRecord>(predicate: #Predicate { $0.category == category })).map(\.merchantKey)
        var kind = FetchDescriptor<CategoryKindRecord>(predicate: #Predicate { $0.category == category })
        kind.fetchLimit = 1
        return (
            try context.fetch(transactions).map(\.id), rules,
            try context.fetch(kind).first.flatMap { CategoryKind(rawValue: $0.kindRaw) }
        )
    }

    /// Takes away a category's stored kind, the last trace of one made with no
    /// transactions, rules or plan; false when something uses it.
    func removeUnusedCategory(_ name: String) throws -> Bool {
        let uses = try uses(of: name)
        guard uses.transactions.isEmpty, uses.rules.isEmpty, !(try budgetSchedule().categories.contains(name)) else { return false }
        try context.delete(model: CategoryKindRecord.self, where: #Predicate { $0.category == name })
        try context.save()
        return true
    }

    func setKind(_ kind: CategoryKind, for category: String) throws {
        var descriptor = FetchDescriptor<CategoryKindRecord>(predicate: #Predicate { $0.category == category })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.kindRaw = kind.rawValue
        } else {
            context.insert(CategoryKindRecord(category: category, kind: kind))
        }
        try context.save()
    }
}

extension CompassStore {
    /// Folds `source` into `target`: its balances (where `target` has none for
    /// that day and source), transactions and goal links move over, and the
    /// source account is removed. For an account Monarch and SimpleFIN name
    /// differently, or one SimpleFIN reports twice. The source's SimpleFIN
    /// feed stays with the target, so the next sync doesn't add it back: a
    /// target with no feed of its own syncs from it, and one with a feed
    /// skips it, so the same money isn't counted twice.
    func merge(_ source: Account, into target: Account) throws {
        let sourceID = source.id
        let targetID = target.id
        var targetRecord = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == targetID })
        targetRecord.fetchLimit = 1
        if let record = try context.fetch(targetRecord).first {
            var feeds = source.mergedExternalIDs
            if let feed = source.externalID {
                if record.externalID == nil {
                    record.externalID = feed
                    record.sourceRaw = BalanceSource.simplefin.rawValue
                } else {
                    feeds.append(feed)
                }
            }
            record.mergedExternalIDs = Array(Set(record.mergedExternalIDs + feeds)).sorted()
        }
        let targetSnapshots = try context.fetch(FetchDescriptor<SnapshotRecord>(predicate: #Predicate { $0.accountID == targetID }))
        let taken = Set(targetSnapshots.map { "\($0.dayOrdinal)|\($0.sourceRaw)" })
        for record in try context.fetch(FetchDescriptor<SnapshotRecord>(predicate: #Predicate { $0.accountID == sourceID })) {
            if taken.contains("\(record.dayOrdinal)|\(record.sourceRaw)") {
                context.delete(record)
            } else {
                record.accountID = targetID
            }
        }
        for record in try context.fetch(FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.accountID == sourceID })) {
            record.accountID = targetID
        }
        for goal in try context.fetch(FetchDescriptor<GoalRecord>()) where goal.accountIDs.contains(sourceID) {
            goal.accountIDs = Array(Set(goal.accountIDs.filter { $0 != sourceID } + [targetID]))
        }
        try context.delete(model: AccountRecord.self, where: #Predicate { $0.id == sourceID })
        try context.save()
        try removeDuplicateTransactions()
    }
}

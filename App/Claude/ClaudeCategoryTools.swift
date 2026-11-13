import Core
import Foundation

/// Merchant rules, categories and added transactions for Claude (seam 31,
/// full write coverage): rules listed, set (optionally refiling the
/// merchant's past transactions) and deleted, categories created, renamed
/// and merged as the Categories sheet does, and cash or anything that didn't
/// sync added to a manual account. Every change is logged with undo.
extension ClaudeTools {
    var categoryReadTools: [ClaudeTool] {
        [
            tool(
                "merchant_rules",
                "Their merchant rules: each merchant (as Compass keys it: lowercased, store numbers dropped) and direction, and the category its new transactions are filed under. A merchant with no rule learns from how its transactions were filed.",
                ["merchant": ["type": "string", "description": "Only rules whose merchant contains this (optional)."]],
                run: { args in try self.merchantRules(args) })
        ]
    }

    var categoryChangeTools: [ClaudeTool] {
        func text(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        let direction: [String: Any] = ["type": "string", "enum": ["out", "in"], "description": "Money out (default) or money in; each has its own rule."]
        return [
            tool(
                "set_merchant_rule",
                "Always file a merchant's transactions in one direction under a category, like Blue Bottle as Coffee. Optionally refiles its past transactions that way too (ones filed as transfers stay).",
                [
                    "merchant": text("The merchant's name, as transactions show it."), "category": text("A category Compass already has."),
                    "direction": direction, "refile_past": ["type": "boolean", "description": "Also refile its past transactions. Default false."]
                ],
                required: ["merchant", "category"], changes: true, run: { args in try self.setMerchantRule(args) }),
            tool(
                "delete_merchant_rule",
                "Delete a merchant rule. The merchant then learns from how its transactions were filed, so new ones may still take that category.",
                ["merchant": text("The merchant's name or its key (from merchant_rules)."), "direction": direction],
                required: ["merchant"], changes: true, run: { args in try self.deleteMerchantRule(args) }),
            tool(
                "create_category", "Add a category, before any transaction is filed under it.",
                [
                    "name": text("Like \"Pet care\"."),
                    "kind": ["type": "string", "enum": ["spending", "income", "transfer"], "description": "Default spending."]
                ],
                required: ["name"], changes: true, destructive: false, run: { args in try self.createCategory(args) }),
            tool(
                "rename_category",
                "Rename a category everywhere: its transactions, merchant rules, kind and budget. To fold it into another category, use merge_category.",
                ["category": text("A category Compass has."), "name": text("Its new name, one no other category has.")],
                required: ["category", "name"], changes: true, run: { args in try self.renameCategory(args) }),
            tool(
                "add_transaction",
                "Add a transaction that didn't sync, like cash, to a manual account (synced accounts are refused: it would count twice once it syncs). No merchant rule is learned from it.",
                [
                    "account": text("A manual account's name or id (from accounts; synced false)."), "date": text("YYYY-MM-DD. Default today."),
                    "amount": text("Dollars, money out negative, like \"-14.50\"."), "merchant": text("Who it was paid to or from."),
                    "category": text("A category Compass already has (optional)."), "note": text("Optional.")
                ],
                required: ["account", "amount", "merchant"], changes: true, destructive: false, run: { args in try self.addTransaction(args) }),
            tool(
                "split_transaction",
                "Split one spending transaction into categories, like a Target run that was part groceries, part household. Spending and the budget count each part in its own category. Parts are dollars without a sign and must add up to the amount. No parts takes the split off. Changing its category later with edit_transaction files all of it that way.",
                [
                    "transaction": text("Its id (from transactions)."),
                    "parts": [
                        "type": "array", "description": "Two or more; empty to take the split off.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "category": text("A spending category Compass already has."),
                                "amount": text("Dollars, like \"40\".")
                            ],
                            "required": ["category", "amount"]
                        ]
                    ]
                ],
                required: ["transaction", "parts"], changes: true, run: { args in try self.splitTransaction(args) }),
            tool(
                "merge_category",
                "Fold one category into another, as the Categories sheet does: its transactions, merchant rules and planned amounts move, and the other keeps its own kind and budget role. Undo folds it back out while what moved is untouched.",
                ["category": text("The category that goes."), "into": text("The category that stays.")],
                required: ["category", "into"], changes: true, run: { args in try self.mergeCategory(args) })
        ]
    }

    func merchantRules(_ args: Arguments) throws -> [String: Any] {
        let filter = args.string("merchant").map { Merchant.key($0) }
        let rows = try store.rules().all
            .filter { key, _ in filter.map { key.contains($0) } ?? true }
            .sorted { $0.key.trimmingCharacters(in: ["+"]) < $1.key.trimmingCharacters(in: ["+"]) }
            .map { key, category -> [String: Any] in
                ["merchant": key.hasPrefix("+") ? String(key.dropFirst()) : key, "direction": key.hasPrefix("+") ? "in" : "out", "category": category]
            }
        var answer: [String: Any] = ["rules": Array(rows.prefix(300)), "count": rows.count]
        if rows.count > 300 { answer["note"] = "The first 300; give merchant to narrow it." }
        return answer
    }

    // MARK: - Rules

    private func setMerchantRule(_ args: Arguments) throws -> [String: Any] {
        let merchant = try args.required("merchant")
        let incoming = try args.choice("direction", in: ["out", "in"]) == "in"
        guard try store.categoryExists(try args.required("category")) else {
            throw Problem("Compass has no category called \(try args.required("category")); categories lists them, and create_category adds one.")
        }
        let category = try store.existingCategory(matching: try args.required("category"))
        let rules = try store.rules()
        let key = try ClaudeRules.ruleKey(merchant: merchant, incoming: incoming, category: category, rules: rules)
        var refiled: [Refiled] = []
        if try args.bool("refile_past") ?? false {
            let kinds = try store.kinds()
            let all = try store.transactions()
            let transfers = Set(all.compactMap(\.category).filter { (kinds[$0] ?? CategoryKind.guess($0)) == .transfer })
            refiled = ClaudeRules.refile(all, key: key, to: category, transfers: transfers)
            try store.setCategories(Dictionary(uniqueKeysWithValues: refiled.map { ($0.id, .some(category)) }))
        }
        try store.setRule(key, to: category)
        let summary =
            "Filed \(merchant) (money \(incoming ? "in" : "out")) as \(category) from now on"
            + (refiled.isEmpty ? "" : ", and refiled \(refiled.count) past \(refiled.count == 1 ? "transaction" : "transactions")")
        try log("set_merchant_rule", summary, .ruleSet(key: key, before: rules.all[key], after: category, refiled: refiled))
        return ["changed": summary, "refiled": refiled.count]
    }

    private func deleteMerchantRule(_ args: Arguments) throws -> [String: Any] {
        let merchant = try args.required("merchant")
        let incoming = try args.choice("direction", in: ["out", "in"]) == "in"
        let key = CategoryRules.key(merchant: merchant, incoming: incoming)
        guard let category = try store.rules().all[key] else {
            throw Problem("\(merchant) has no money-\(incoming ? "in" : "out") rule; merchant_rules lists them.")
        }
        try store.setRule(key, to: nil)
        let summary = "Deleted the rule filing \(merchant) as \(category)"
        try log("delete_merchant_rule", summary, .ruleDeleted(key: key, category: category))
        return ["deleted": summary, "note": "\(merchant) now learns from how its transactions were filed, so new ones may still be guessed as \(category)."]
    }

    // MARK: - Categories

    private func createCategory(_ args: Arguments) throws -> [String: Any] {
        let name = try ClaudeRules.newCategory(try args.required("name"), among: try store.allCategories())
        let kind = CategoryKind(rawValue: try args.choice("kind", in: ["spending", "income", "transfer"]) ?? "spending") ?? .spending
        try store.setKind(kind, for: name)
        let summary = "Added the \(kind.rawValue) category \(name)"
        try log("create_category", summary, .categoryCreated(name: name, kind: kind))
        return ["added": summary]
    }

    private func renameCategory(_ args: Arguments) throws -> [String: Any] {
        let (old, new) = try ClaudeRules.rename(try args.required("category"), to: try args.required("name"), among: try store.allCategories())
        try store.renameCategory(old, to: new)
        let summary = "Renamed the category \(old) to \(new)"
        try log("rename_category", summary, .categoryRenamed(from: old, to: new))
        return ["changed": summary]
    }

    private func mergeCategory(_ args: Arguments) throws -> [String: Any] {
        let (from, into) = try ClaudeRules.merge(try args.required("category"), into: try args.required("into"), among: try store.allCategories())
        let uses = try store.uses(of: from)
        let splits = Dictionary(
            uniqueKeysWithValues: try store.splitTransactions().filter { $0.splits.contains { $0.category == from } }
                .map { ($0.id, TransactionEdit($0)) })
        let before = try store.budgetSchedule()
        let dropped = before.billDropped(merging: from, into: into)
        try store.renameCategory(from, to: into)
        let merge = CategoryMerge(
            from: from, into: into, transactions: uses.transactions, rules: uses.rules, kind: uses.kind,
            budgetBefore: before, budgetAfter: try store.budgetSchedule(), splits: splits)
        let count = uses.transactions.count
        let summary = "Merged \(from) into \(into): \(count) \(count == 1 ? "transaction" : "transactions") moved"
        try log("merge_category", summary, .categoryMerged(merge))
        var answer: [String: Any] = ["changed": summary]
        if let dropped {
            answer["note"] =
                "\(into) isn't a fixed bill, so \(from)'s planned \(Self.money(dropped)) a month was dropped and its charges count as flexible spending."
        }
        return answer
    }

    // MARK: - Transactions

    private func addTransaction(_ args: Arguments) throws -> [String: Any] {
        let account = try find(try args.required("account"), in: try store.accounts())
        guard let amount = try args.signedAmount("amount") else { throw Problem("amount is required.") }
        var category: String?
        if let typed = args.string("category") {
            guard try store.categoryExists(typed) else { throw Problem("Compass has no category called \(typed); categories lists them.") }
            category = try store.existingCategory(matching: typed)
        }
        let transaction = try ClaudeRules.newTransaction(
            account: account, day: try args.day("date") ?? today, amount: amount,
            merchant: try args.required("merchant"), category: category,
            note: args.string("note") ?? "", today: today)
        try store.add(transaction)
        let summary =
            "Added \(Self.money(abs(amount))) \(amount < 0 ? "to" : "from") \(transaction.merchant) on \(Self.longDay(transaction.day)) in \(Self.displayName(account.name))"
            + (category.map { ", filed as \($0)" } ?? "")
        try log("add_transaction", summary, .transactionAdded(transaction))
        return ["added": summary, "transaction": transaction.id.uuidString]
    }

    private func splitTransaction(_ args: Arguments) throws -> [String: Any] {
        guard let id = UUID(uuidString: try args.required("transaction")),
            let transaction = try store.transaction(id)
        else { throw Problem("No transaction with that id; ids come from transactions.") }
        guard let list = args.values["parts"] as? [Any] else { throw Problem("parts is a list of {category, amount}.") }
        let parts = try list.map { item -> (category: String, amount: Decimal) in
            guard let object = item as? [String: Any], let typed = object["category"] as? String else {
                throw Problem("Each part is {\"category\": \"Groceries\", \"amount\": \"40\"}.")
            }
            guard try store.categoryExists(typed) else {
                throw Problem("Compass has no category called \(typed); categories lists them, and create_category adds one.")
            }
            guard let amount = try Arguments(object).signedAmount("amount") else { throw Problem("Each part needs an amount.") }
            return (try store.existingCategory(matching: typed), amount)
        }
        if parts.isEmpty, !transaction.isSplit { throw Problem("It isn't split; nothing to change.") }
        let split = try Splits.split(transaction, into: parts, kinds: try store.kinds())
        let (before, after) = (TransactionEdit(transaction), TransactionEdit(split))
        try store.save(after, for: id)
        let day = transaction.day.startDate(in: .current).formatted(.dateTime.month(.abbreviated).day())
        let summary =
            split.isSplit
            ? "Split \(transaction.merchant) on \(day): " + split.splits.map { "\($0.category) \(Self.money(abs($0.amount)))" }.joined(separator: ", ")
            : "Took the split off \(transaction.merchant) on \(day)"
        try log("split_transaction", summary, .transactionEdited(id: id, before: before, after: after))
        return ["changed": summary, "transaction": id.uuidString]
    }

    // MARK: - Undo

    /// Takes back one of these changes, for `undo`; nil when it isn't one.
    func undoCategory(_ change: ClaudeChange) throws -> Bool {
        switch change {
        case .ruleSet(let key, let before, let after, let refiled):
            guard try store.rules().all[key] == after else { throw Self.changedSince }
            let back = ClaudeRules.putBack(refiled, filedAs: after, current: try store.categories(of: refiled.map(\.id)))
            try store.setCategories(Dictionary(uniqueKeysWithValues: back.map { ($0.id, $0.before) }))
            try store.setRule(key, to: before)
        case .ruleDeleted(let key, let category):
            guard try store.rules().all[key] == nil else { throw Self.changedSince }
            try store.setRule(key, to: category)
        case .categoryCreated(let name, _):
            guard try store.removeUnusedCategory(name) else {
                throw Problem("\(name) is in use now (transactions, rules or the budget). Merge it into another category instead.")
            }
        case .categoryRenamed(let from, let to):
            guard try store.categoryExists(to), !(try store.categoryExists(from)) else { throw Self.changedSince }
            try store.renameCategory(to, to: from)
        case .categoryMerged(let merge):
            guard try store.categoryExists(merge.into) else { throw Problem("\(merge.into) is gone.") }
            guard !(try store.categoryExists(merge.from)) else {
                throw Problem("There's a category called \(merge.from) again, so it can't be folded back out.")
            }
            guard
                let budget = ClaudeRules.undoBudget(
                    current: try store.budgetSchedule(), before: merge.budgetBefore,
                    after: merge.budgetAfter, today: Month(today))
            else { throw Self.changedSince }
            // Splits first: refiling a whole transaction would take its split off.
            let folded = merge.splits ?? [:]
            let now = try store.transactions(Array(folded.keys)).mapValues(TransactionEdit.init)
            let unfolded = ClaudeRules.unfold(folded, from: merge.from, into: merge.into, current: now)
            for (id, edit) in unfolded { try store.save(edit, for: id) }
            let moved = merge.transactions.filter { unfolded[$0] == nil }.map { Refiled(id: $0, before: merge.from) }
            let back = ClaudeRules.putBack(moved, filedAs: merge.into, current: try store.categories(of: moved.map(\.id)))
            try store.setCategories(Dictionary(uniqueKeysWithValues: back.map { ($0.id, $0.before) }))
            let rules = try store.rules().all
            for key in merge.rules where rules[key] == merge.into { try store.setRule(key, to: merge.from) }
            if let kind = merge.kind { try store.setKind(kind, for: merge.from) }
            try store.save(budget)
        case .transactionAdded(let added):
            guard let current = try store.transaction(added.id) else { throw Problem("That transaction is gone already.") }
            guard current == added else { throw Self.changedSince }
            try store.deleteTransaction(added.id)
        default:
            return false
        }
        return true
    }
}

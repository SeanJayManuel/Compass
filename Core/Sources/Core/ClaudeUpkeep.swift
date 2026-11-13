import Foundation

/// The rest of what Claude may keep up through chat (seam 31, full write
/// coverage, Oct 31, 2026): events' titles and notes, deleting Playbook
/// entries and sizes, editing, archiving and deleting habits and removing
/// check-ins, retiring goals and their rewards, pay, accounts' names and
/// balances, and reminders moved, deleted and reopened. Each is checked as
/// its screen checks it, and undo restores only what still holds Claude's change.
extension ClaudeRules {
    // MARK: Events

    /// A title or notes (empty clears them) for one of Claude's own events.
    public static func editEvent(_ event: ClaudeEvent, title: String?, notes: String?) throws -> ClaudeEvent {
        var edited = event
        if let title {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ClaudeRefusal("An event needs a title.") }
            edited.title = title
        }
        if let notes {
            let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            edited.notes = notes.isEmpty ? nil : notes
        }
        guard (edited.title, edited.notes) != (event.title, event.notes) else {
            throw ClaudeRefusal("That's what \(event.title) already says; nothing to change.")
        }
        return edited
    }

    // MARK: The Playbook

    /// A deleted entry comes back unless one of its title is in its area by then.
    public static func canRestoreDeleted(_ entry: PlaybookEntry, among entries: [PlaybookEntry]) -> Bool {
        !entries.contains { $0.id == entry.id || ($0.area.sameTitle(as: entry.area) && $0.title.sameTitle(as: entry.title)) }
    }

    /// Without the line of this label (ignoring case).
    public static func removeSize(_ sizes: PlaybookSizes, label: String) throws -> PlaybookSizes {
        var changed = sizes
        guard let index = changed.rows.firstIndex(where: { $0.label.sameTitle(as: label) }) else {
            throw ClaudeRefusal("No size called \(label). Sizes: \(sizes.rows.map(\.label).joined(separator: ", ")).")
        }
        changed.rows.remove(at: index)
        return changed
    }

    // MARK: Habits

    /// Title or times a week, as the habit editor allows. A linked
    /// habit takes its reminder's title, and an archived one is unarchived first.
    public static func editHabit(_ habit: Habit, title: String?, perWeek: Int?, among habits: [Habit]) throws -> Habit {
        guard !habit.archived else { throw ClaudeRefusal("\(habit.title) is archived; unarchive it first.") }
        var edited = habit
        if let title {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ClaudeRefusal("A habit needs a title.") }
            if habit.reminder != nil, title != habit.title {
                throw ClaudeRefusal("\(habit.title) follows its daily reminder's title; rename the reminder with edit_reminder instead.")
            }
            edited.title = title
        }
        if let perWeek {
            guard (1...7).contains(perWeek) else { throw ClaudeRefusal("per_week must be from 1 to 7.") }
            edited.perWeek = perWeek
        }
        guard edited != habit else { throw ClaudeRefusal("That's what \(habit.title) already is; nothing to change.") }
        try checkTitleFree(edited, among: habits)
        return edited
    }

    /// Archived (tracking stops) or back again, its title free among active habits.
    public static func archiveHabit(_ habit: Habit, archived: Bool, among habits: [Habit]) throws -> Habit {
        guard habit.archived != archived else {
            throw ClaudeRefusal("\(habit.title) is \(archived ? "archived" : "active") already; nothing to change.")
        }
        var changed = habit
        changed.archived = archived
        if !archived { try checkTitleFree(changed, among: habits) }
        return changed
    }

    /// The earlier title, times a week and archiving back, keeping
    /// check-ins since; nil when any of those changed since.
    public static func undoHabitEdit(current: Habit, before: Habit, after: Habit) -> Habit? {
        func definition(_ habit: Habit) -> [AnyHashable] { [habit.title, habit.perWeek, habit.archived] }
        guard definition(current) == definition(after) else { return nil }
        var restored = current
        (restored.title, restored.perWeek, restored.archived) = (before.title, before.perWeek, before.archived)
        return restored
    }

    /// A habit linked to a daily repeat would only be made again, so it's archived instead.
    public static func checkDelete(_ habit: Habit) throws {
        if habit.reminder != nil {
            throw ClaudeRefusal(
                "\(habit.title) is linked to a daily reminder, and Compass makes a habit for every daily repeat, so it would come back. Archive it instead (archive_habit), or delete the reminder's repeat in Reminders."
            )
        }
    }

    /// A deleted habit comes back whole unless its id or an active habit of its title is there by then.
    public static func canRestoreDeleted(_ habit: Habit, among habits: [Habit]) -> Bool {
        !habits.contains { $0.id == habit.id || (!$0.archived && $0.title.sameTitle(as: habit.title)) }
    }

    /// The day unticked as the Life overview unticks it (a linked habit's
    /// day stays settled); nil when it wasn't ticked.
    public static func removeCheckIn(_ habit: Habit, on day: Day, today: Day) throws -> Habit? {
        guard !habit.archived else { throw ClaudeRefusal("\(habit.title) is archived.") }
        guard habit.checkIns.contains(day) else { return nil }
        return HabitReminderLink.toggle(habit, on: day, reminders: [], today: today).habit
    }

    private static func checkTitleFree(_ habit: Habit, among habits: [Habit]) throws {
        if habits.contains(where: { $0.id != habit.id && !$0.archived && $0.title.sameTitle(as: habit.title) }) {
            throw ClaudeRefusal("There's already a habit called \(habit.title).")
        }
    }
}

extension ClaudeRules {
    // MARK: Goals

    /// An active goal retired, with their reason; never deleted.
    public static func retireGoal(_ goal: Goal, reason: String) throws -> Goal {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw ClaudeRefusal("Say why it's retired, in their words; Goals shows it.") }
        switch goal.status {
        case .active: return GoalLifecycle.retire(goal, reason: reason)
        case .achieved: throw ClaudeRefusal("\(goal.name) is reached, so it stays reached; nothing to retire.")
        case .retired: throw ClaudeRefusal("\(goal.name) is retired already.")
        }
    }

    /// Active again while it's still retired as Claude left it.
    public static func undoRetire(current: Goal, before: Goal, after: Goal) -> Goal? {
        guard current.status == after.status else { return nil }
        var restored = current
        restored.status = before.status
        return restored
    }

    /// A goal's reward: its name and cost (spending, never an asset), and
    /// the day it was claimed, only once the goal is reached, on or after
    /// that day and not after today. What isn't given stays.
    public static func setReward(_ goal: Goal, name: String?, cost: Decimal?, claimedOn: Day?, today: Day) throws -> Goal {
        if case .retired = goal.status { throw ClaudeRefusal("\(goal.name) is retired, so it has no reward to set.") }
        var changed = goal
        changed.reward = try reward(goal.reward, of: goal.name, name: name, cost: cost, claimedOn: claimedOn, today: today) { claimedOn in
            guard case .achieved(let reached, _) = goal.status else {
                throw ClaudeRefusal(
                    "\(goal.name) isn't reached yet, so its reward can't be claimed. Set its name and cost now, and claim it once it's reached.")
            }
            guard claimedOn >= reached else { throw ClaudeRefusal("\(goal.name) was reached \(reached.iso); a reward isn't claimed before that.") }
        }
        return changed
    }

    /// A This Quarter reminder's reward, kept on its target link: set as a
    /// goal's is, and claimed only while its progress (nil when the number
    /// isn't known) is at 1.
    public static func setReward(
        _ link: ReminderMeasure, name: String?, cost: Decimal?, claimedOn: Day?, progress: Decimal?,
        today: Day
    ) throws -> ReminderMeasure {
        var changed = link
        changed.reward = try reward(link.reward, of: link.title, name: name, cost: cost, claimedOn: claimedOn, today: today) { _ in
            guard let progress, progress >= 1 else {
                // Rounded down first: intValue misreads a fraction with many digits.
                let at =
                    progress.map { fraction -> String in
                        var percent = fraction * 100, whole = Decimal()
                        NSDecimalRound(&whole, &percent, 0, .down)
                        return " (it's at \(NSDecimalNumber(decimal: whole).intValue)%)"
                    } ?? ""
                throw ClaudeRefusal("\(link.title) isn't reached yet\(at), so its reward can't be claimed. Claim it once its progress reaches 100%.")
            }
        }
        return changed
    }

    private static func reward(
        _ current: Reward?, of owner: String, name: String?, cost: Decimal?, claimedOn: Day?, today: Day,
        claimable: (Day) throws -> Void
    ) throws -> Reward {
        var reward = current ?? Reward(name: "")
        if let name { reward.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let cost {
            guard cost >= 0 else { throw ClaudeRefusal("A reward's cost can't be below zero.") }
            reward.cost = cost
        }
        if let claimedOn {
            try claimable(claimedOn)
            guard claimedOn <= today else { throw ClaudeRefusal("\(claimedOn.iso) hasn't happened yet.") }
            reward.claimedOn = claimedOn
        }
        guard !reward.name.isEmpty else { throw ClaudeRefusal("A reward needs a name, like \"Tudor BB54\".") }
        guard reward != current else { throw ClaudeRefusal("That's \(owner)'s reward already; nothing to change.") }
        return reward
    }

    // MARK: Reminders

    public static func checkMove(_ reminder: Reminder, to list: ReminderList) throws {
        guard reminder.listID != list.id else { throw ClaudeRefusal("\(reminder.title) is in \(list.title) already.") }
    }

    /// A repeat's schedule wouldn't come back with an undo, so repeats are deleted in Reminders.
    public static func checkDelete(_ reminder: Reminder) throws {
        if reminder.repeats {
            throw ClaudeRefusal("\(reminder.title) repeats, and undo couldn't bring its schedule back; the owner can delete it in Reminders.")
        }
    }

    /// A reminder ticked off lately, by its id or the latest with its title.
    public static func doneReminder(_ wanted: String, in done: [CompletedReminder]) throws -> CompletedReminder {
        if let same = done.first(where: { $0.id == wanted }) { return same }
        let titled = done.filter { $0.title.sameTitle(as: wanted) }
        guard let latest = titled.max(by: { $0.day < $1.day }) else {
            throw ClaudeRefusal("Nothing called \(wanted) was ticked off lately; the reminders tool lists what was, with ids.")
        }
        guard titled.filter({ $0.day == latest.day }).count == 1 else {
            throw ClaudeRefusal("More than one reminder called \(wanted) was ticked off that day; use its id from the reminders tool.")
        }
        return latest
    }

    /// The done copy Reminders keeps when a repeat is ticked: its title, in
    /// its list, ticked that day.
    public static func doneCopy(title: String, listID: String, on day: Day, among done: [CompletedReminder]) -> String? {
        done.last { $0.listID == listID && $0.day == day && $0.title.sameTitle(as: title) }?.id
    }

    /// The edit taken back while what it touched is still as Claude left it;
    /// notes and a repeat it left alone (nil) stay as they are now.
    public static func undoReminderEdit(current: ReminderEdit, before: ReminderEdit, after: ReminderEdit) -> ReminderEdit? {
        var compared = current
        if after.notes == nil { compared.notes = nil }
        if after.repeating == nil { compared.repeating = nil }
        return compared == after ? before : nil
    }

    // MARK: Pay

    /// Settings › Pay's figures, checked as Settings checks them.
    public static func editPay(_ profile: PayProfile, _ edit: PayEdit) throws -> PayProfile {
        var changed = profile
        if let salary = edit.annualSalary {
            guard salary > 0 else { throw ClaudeRefusal("annual_salary must be above zero.") }
            changed.annualSalary = salary
        }
        if let every = edit.everyDays {
            guard every == 7 || every == 14 else { throw ClaudeRefusal("They've paid every 7 or 14 days.") }
            changed.everyDays = every
        }
        if let payday = edit.knownPayday { changed.knownPayday = payday }
        for (name, percent) in [
            ("retirement_percent", edit.retirementPercent), ("match_percent", edit.matchPercent),
            ("match_up_to_percent", edit.matchUpToPercent)
        ] {
            if let percent, !(0...100).contains(percent) { throw ClaudeRefusal("\(name) must be from 0 to 100.") }
        }
        for (name, amount) in [("stock_per_check", edit.stockPerCheck), ("stock_company_per_check", edit.stockCompanyPerCheck)] {
            if let amount, amount < 0 { throw ClaudeRefusal("\(name) can't be below zero.") }
        }
        if let percent = edit.retirementPercent { changed.retirementPercent = percent }
        if let preTax = edit.retirementPreTax { changed.retirementPreTax = preTax }
        if let percent = edit.matchPercent { changed.matchPercent = percent }
        if let percent = edit.matchUpToPercent { changed.matchUpToPercent = percent }
        if let amount = edit.stockPerCheck { changed.stockPerCheck = amount }
        if let amount = edit.stockCompanyPerCheck { changed.stockCompanyPerCheck = amount }
        guard changed != profile else { throw ClaudeRefusal("That's what their pay settings say already; nothing to change.") }
        return changed
    }

    /// When an expected bonus or vest lands: a day, or just a month.
    public enum PayWhen: Hashable, Sendable {
        case day(Day)
        case month(Month)
    }

    /// A bonus or vest they expect, as Settings › Pay keeps them: an amount
    /// above zero, and a title (the kind's name when none is given).
    public static func expectedPay(
        kind: ExpectedPay.Kind, title: String?, gross: Decimal, on when: PayWhen?, estimate: Bool,
        note: String, id: UUID = UUID()
    ) throws -> ExpectedPay {
        guard gross > 0 else { throw ClaudeRefusal("amount must be above zero.") }
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var item = ExpectedPay(
            id: id, kind: kind, title: title.isEmpty ? (kind == .bonus ? "Bonus" : "Vest") : title,
            gross: gross, note: note.trimmingCharacters(in: .whitespacesAndNewlines), estimate: estimate)
        switch when {
        case .day(let day): item.day = day
        case .month(let month): item.month = month
        case nil: break
        }
        return item
    }

    /// Undoes a pay change: each setting and expected item it touched goes
    /// back, and anything else changed since stays. Nil when something it
    /// touched changed since.
    public static func undoPay(current: PayProfile, before: PayProfile, after: PayProfile) -> PayProfile? {
        var restored = current
        func field<Value: Equatable>(_ path: WritableKeyPath<PayProfile, Value>) -> Bool {
            guard before[keyPath: path] != after[keyPath: path] else { return true }
            guard current[keyPath: path] == after[keyPath: path] else { return false }
            restored[keyPath: path] = before[keyPath: path]
            return true
        }
        guard field(\.annualSalary), field(\.everyDays), field(\.knownPayday), field(\.retirementPercent),
            field(\.retirementPreTax), field(\.matchPercent), field(\.matchUpToPercent), field(\.stockPerCheck),
            field(\.stockCompanyPerCheck)
        else { return nil }
        let was = Dictionary(uniqueKeysWithValues: before.expected.map { ($0.id, $0) })
        let made = Dictionary(uniqueKeysWithValues: after.expected.map { ($0.id, $0) })
        for id in Set(was.keys).union(made.keys) where was[id] != made[id] {
            let now = restored.expected.firstIndex { $0.id == id }
            guard now.map({ restored.expected[$0] }) == made[id] else { return nil }
            if let now { restored.expected.remove(at: now) }
            if let old = was[id] { restored.expected.append(old) }
        }
        return restored
    }

    // MARK: Accounts

    /// A new name, never with an account number in it: four digits in a row
    /// (other than a year, as in "2019 Civic") or more.
    public static func renameAccount(_ account: Account, to name: String, among accounts: [Account]) throws -> Account {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ClaudeRefusal("An account needs a name.") }
        guard name.range(of: #"\d{5,}|(?<!\d)\d{4}(?!\d)(?<!(19|20)\d\d)"#, options: .regularExpression) == nil else {
            throw ClaudeRefusal("Account names never hold account numbers; leave the digits out.")
        }
        guard name != account.name else { throw ClaudeRefusal("\(account.name) is called that already; nothing to change.") }
        if accounts.contains(where: { $0.id != account.id && $0.name.sameTitle(as: name) }) {
            throw ClaudeRefusal("Another account is called \(name).")
        }
        var renamed = account
        renamed.name = name
        return renamed
    }

    /// A manual account, like Cash, named as a rename allows, with its balance today.
    public static func newAccount(
        name: String, accountClass: AccountClass, balance: Decimal, on day: Day,
        among accounts: [Account]
    ) throws -> (Account, BalanceSnapshot) {
        let placeholder = Account(name: "", accountClass: accountClass, source: .manual)
        let account = try renameAccount(placeholder, to: name, among: accounts)
        return (
            account,
            BalanceSnapshot(
                accountID: account.id, day: day, source: .manual,
                balance: accountClass.storedBalance(entered: balance))
        )
    }

    /// Archived today (closed: kept in history, out of totals from then), or open again.
    public static func archiveAccount(_ account: Account, archived: Bool, today: Day) throws -> Account {
        guard (account.archivedOn != nil) != archived else {
            throw ClaudeRefusal("\(account.name) is \(archived ? "archived" : "open") already; nothing to change.")
        }
        var changed = account
        changed.archivedOn = archived ? today : nil
        return changed
    }

    /// A balance typed for a manual or imported account (a debt as what's
    /// owed), today or earlier. Synced accounts take their balances from sync.
    public static func balance(_ entered: Decimal, for account: Account, on day: Day, today: Day) throws -> BalanceSnapshot {
        guard account.source != .simplefin else {
            throw ClaudeRefusal("\(account.name) takes its balance from sync; a typed balance would pin it. Only manual accounts take a balance from Claude.")
        }
        guard account.archivedOn == nil else { throw ClaudeRefusal("\(account.name) is archived.") }
        guard day <= today else { throw ClaudeRefusal("\(day.iso) hasn't happened yet.") }
        return BalanceSnapshot(accountID: account.id, day: day, source: .manual, balance: account.accountClass.storedBalance(entered: entered))
    }
}

/// Settings › Pay's figures Claude may change; nil leaves one as it is.
public struct PayEdit: Hashable, Sendable {
    public var annualSalary: Decimal?
    public var everyDays: Int?
    public var knownPayday: Day?
    public var retirementPercent: Decimal?
    public var retirementPreTax: Bool?
    public var matchPercent: Decimal?
    public var matchUpToPercent: Decimal?
    public var stockPerCheck: Decimal?
    public var stockCompanyPerCheck: Decimal?

    public init(
        annualSalary: Decimal? = nil, everyDays: Int? = nil, knownPayday: Day? = nil, retirementPercent: Decimal? = nil,
        retirementPreTax: Bool? = nil, matchPercent: Decimal? = nil, matchUpToPercent: Decimal? = nil,
        stockPerCheck: Decimal? = nil, stockCompanyPerCheck: Decimal? = nil
    ) {
        self.annualSalary = annualSalary
        self.everyDays = everyDays
        self.knownPayday = knownPayday
        self.retirementPercent = retirementPercent
        self.retirementPreTax = retirementPreTax
        self.matchPercent = matchPercent
        self.matchUpToPercent = matchUpToPercent
        self.stockPerCheck = stockPerCheck
        self.stockCompanyPerCheck = stockCompanyPerCheck
    }
}

extension ClaudeRules {
    // MARK: Merchant rules and categories

    /// The rule key for "always file this merchant, in this direction, as
    /// this category" (seam 11's keys); refused when the merchant has no
    /// words left once store numbers go, or the rule is that already.
    public static func ruleKey(merchant: String, incoming: Bool, category: String, rules: CategoryRules) throws -> String {
        guard !Merchant.key(merchant).isEmpty else { throw ClaudeRefusal("\(merchant) has no name left once store numbers go; give the merchant's name.") }
        let key = CategoryRules.key(merchant: merchant, incoming: incoming)
        guard rules.all[key] != category else { throw ClaudeRefusal("\(merchant) is filed as \(category) already; nothing to change.") }
        return key
    }

    /// The merchant's transactions in the rule's direction that filing
    /// under `category` would change, with what each was; ones filed as
    /// transfers stay, since moving money is about the occasion, and so do
    /// splits, made on purpose.
    public static func refile(_ transactions: [Transaction], key: String, to category: String, transfers: Set<String>) -> [Refiled] {
        transactions.filter { transaction in
            CategoryRules.key(for: transaction) == key && transaction.category != category && !transaction.isSplit
                && !(transaction.category.map(transfers.contains) ?? false)
        }
        .map { Refiled(id: $0.id, before: $0.category) }
    }

    /// The refiled transactions still filed as `category`, to put back.
    public static func putBack(_ refiled: [Refiled], filedAs category: String, current: [UUID: String?]) -> [Refiled] {
        refiled.filter { current[$0.id] == .some(category) }
    }

    /// The split transactions a merge folded, as they were, for those still
    /// exactly as the merge left them.
    public static func unfold(
        _ splits: [UUID: TransactionEdit], from: String, into: String,
        current: [UUID: TransactionEdit]
    ) -> [UUID: TransactionEdit] {
        splits.filter { id, before in
            var transaction = Transaction(accountID: UUID(), day: Day(ordinal: 0), amount: 0, merchant: "", externalID: "")
            before.apply(to: &transaction)
            return current[id] == TransactionEdit(Splits.renaming(transaction, from, to: into))
        }
    }

    /// A new category's name, tidied, that no category has yet (ignoring case).
    public static func newCategory(_ typed: String, among names: Set<String>) throws -> String {
        let name = CategoryRules.tidy(typed)
        guard !name.isEmpty else { throw ClaudeRefusal("A category needs a name.") }
        if let existing = CategoryRules.existing(name, among: names) { throw ClaudeRefusal("\(existing) is a category already.") }
        return name
    }

    /// The category as Compass has it, and its new name, which no other has.
    public static func rename(_ typed: String, to newName: String, among names: Set<String>) throws -> (String, String) {
        let old = try category(typed, among: names)
        let new = CategoryRules.tidy(newName)
        guard !new.isEmpty, new != old else { throw ClaudeRefusal("Give \(old) a new name.") }
        if let existing = CategoryRules.existing(new, among: names.subtracting([old])) {
            throw ClaudeRefusal("\(existing) is a category already; use merge_category to fold \(old) into it.")
        }
        return (old, new)
    }

    /// Two different categories Compass has, as it has them.
    public static func merge(_ typed: String, into target: String, among names: Set<String>) throws -> (String, String) {
        let from = try category(typed, among: names)
        guard let into = CategoryRules.existing(target, among: names) else {
            throw ClaudeRefusal("There's no category called \(target); use rename_category to give \(from) that name.")
        }
        guard into != from else { throw ClaudeRefusal("That's the same category.") }
        return (from, into)
    }

    private static func category(_ typed: String, among names: Set<String>) throws -> String {
        guard let name = CategoryRules.existing(typed, among: names) else {
            throw ClaudeRefusal("There's no category called \(typed); categories lists them.")
        }
        return name
    }
}

/// A transaction a merchant rule refiled, and the category it had.
public struct Refiled: Hashable, Codable, Sendable {
    public var id: UUID
    public var before: String?

    public init(id: UUID, before: String?) {
        self.id = id
        self.before = before
    }
}

/// A category folded into another, with what undo needs to fold it back out.
public struct CategoryMerge: Hashable, Codable, Sendable {
    public var from: String
    public var into: String
    /// The transactions and merchant rules (their keys) that moved.
    public var transactions: [UUID]
    public var rules: [String]
    /// Its own kind, when it had one stored.
    public var kind: CategoryKind?
    public var budgetBefore: BudgetSchedule
    public var budgetAfter: BudgetSchedule
    /// Split transactions with a part in `from`, as they were (seam 43).
    public var splits: [UUID: TransactionEdit]?

    public init(
        from: String, into: String, transactions: [UUID], rules: [String], kind: CategoryKind?,
        budgetBefore: BudgetSchedule, budgetAfter: BudgetSchedule, splits: [UUID: TransactionEdit] = [:]
    ) {
        self.splits = splits
        self.from = from
        self.into = into
        self.transactions = transactions
        self.rules = rules
        self.kind = kind
        self.budgetBefore = budgetBefore
        self.budgetAfter = budgetAfter
    }
}

extension ClaudeRules {
    // MARK: Adding a transaction

    /// What an added transaction's external id starts with, so sync,
    /// dedupe and the Monarch import never take it for one of theirs.
    public static let addedPrefix = "claude-"

    /// Cash or anything that didn't sync, on a manual or imported account:
    /// today or earlier, an amount (money out negative) and a merchant. A
    /// synced account gets its transactions from sync, where one added here
    /// would later count twice.
    public static func newTransaction(
        account: Account, day: Day, amount: Decimal, merchant: String, category: String?,
        note: String, today: Day
    ) throws -> Transaction {
        guard account.source != .simplefin else {
            throw ClaudeRefusal(
                "\(account.name) takes its transactions from sync, so one added here would count twice once it syncs. Add it to a manual account, like Cash.")
        }
        guard account.archivedOn == nil else { throw ClaudeRefusal("\(account.name) is archived.") }
        guard day <= today else { throw ClaudeRefusal("\(day.iso) hasn't happened yet.") }
        guard amount != 0 else { throw ClaudeRefusal("amount can't be zero; money out is negative, like \"-14.50\".") }
        let merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !merchant.isEmpty else { throw ClaudeRefusal("A transaction needs a merchant.") }
        var transaction = Transaction(
            accountID: account.id, day: day, amount: amount, merchant: merchant, statement: merchant,
            category: category, externalID: addedPrefix + UUID().uuidString)
        transaction.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return transaction
    }
}

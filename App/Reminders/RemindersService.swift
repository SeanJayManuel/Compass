import AppKit
import Core
import EventKit
import Observation

/// The owner's open reminders, read live from Reminders through EventKit. Nothing
/// is kept: no records, no backup. Ticking one off marks it done in Reminders
/// itself, so it syncs wherever Reminders does.
///
/// In the sandbox (every debug run: snapshots, the demo, perf) it holds fixed
/// sample reminders and never touches EventKit, so no run asks for access.
@Observable
final class RemindersService {
    enum Access { case notAsked, denied, granted }

    private(set) var access: Access
    private(set) var reminders: [Reminder] = []
    private(set) var lists: [ReminderList] = []
    /// Reminders ticked off in the last three months, for carrying ticks
    /// over to the habits they're linked to.
    private(set) var completed: [CompletedReminder] = []
    /// Whether both the open and the done reminders have been read, so a
    /// new habit made from a daily repeat starts with its history.
    private(set) var loaded = false
    /// Set when a tick couldn't be saved, in words for the card.
    private(set) var failure: String?
    /// The sandbox's ticked-off samples, so undo can bring them back.
    @ObservationIgnored private var sampleDone: [String: Reminder] = [:]

    /// Nil in the sandbox.
    let store: EKEventStore?
    /// Called each time both reads land, so the Playbook's reminders follow
    /// changes made in Reminders (`PlaybookReminders`).
    @ObservationIgnored var onLoad: (() -> Void)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Bumped by each fetch and each tick, so an older fetch that lands late
    /// can't put back a list from before.
    @ObservationIgnored private var generation = 0
    /// How many of the current fetch's two reads (open, done) have landed.
    @ObservationIgnored private var landed = 0

    init(demo: Bool) {
        if demo {
            store = nil
            access = .granted
            (lists, reminders) = Self.sample(today: Day(.now, in: .current))
            loaded = true
            return
        }
        let store = EKEventStore()
        self.store = store
        access = Self.access(EKEventStore.authorizationStatus(for: .reminder))
        // Any change in Reminders, here or synced from their phone.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            // Access turned on (or off) in System Settings while Compass was open.
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recheckAccess() }
            }
        ]
        refresh()
    }

    /// Shows the system prompt the first time; after a no, macOS only lets
    /// them change it in System Settings.
    func requestAccess() async {
        guard let store else { return }
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        access = granted ? .granted : .denied
        // A store made before access was granted can hold an empty cache.
        store.reset()
        refresh()
    }

    private func recheckAccess() {
        guard let store else { return }
        let now = Self.access(EKEventStore.authorizationStatus(for: .reminder))
        guard now != access else { return }
        access = now
        store.reset()
        if now != .granted { reminders = []; lists = []; completed = []; loaded = false }
        refresh()
    }

    func refresh() {
        guard let store, access == .granted else { return }
        failure = nil
        generation += 1
        let fetch = generation
        lists = store.calendars(for: .reminder).map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        // Called off the main thread with values that aren't Sendable, so
        // they become plain values there.
        landed = 0
        store.fetchReminders(matching: predicate) { [weak self] found in
            let mapped = (found ?? []).map(Self.reminder)
            Task { @MainActor in
                guard let self, self.generation == fetch else { return }
                self.reminders = mapped
                self.landed += 1
                if self.landed == 2 { self.loaded = true; self.onLoad?() }
            }
        }
        let since = Calendar.current.date(
            byAdding: .day, value: 1 - HabitReminderLink.lookback,
            to: Calendar.current.startOfDay(for: .now))
        let done = store.predicateForCompletedReminders(withCompletionDateStarting: since, ending: nil, calendars: nil)
        store.fetchReminders(matching: done) { [weak self] found in
            let mapped = (found ?? []).compactMap(Self.completed)
            Task { @MainActor in
                guard let self, self.generation == fetch else { return }
                self.completed = mapped
                self.landed += 1
                if self.landed == 2 { self.loaded = true; self.onLoad?() }
            }
        }
    }

    /// Marks it done in Reminders. A daily repeat moves on to its next day;
    /// with `moveToToday`, it's set due today first, so one days behind lands
    /// on tomorrow.
    func complete(_ id: String, moveToToday: Bool = false) {
        failure = nil
        guard let store else {
            completeSample(id)
            return
        }
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        if moveToToday, var due = item.dueDateComponents {
            // Today's date where it's kept, so a reminder with a zone of its own lands on today here.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = due.timeZone ?? .current
            let today = calendar.dateComponents([.year, .month, .day], from: .now)
            (due.year, due.month, due.day) = (today.year, today.month, today.day)
            item.dueDateComponents = due
            if var start = item.startDateComponents {
                (start.year, start.month, start.day) = (today.year, today.month, today.day)
                item.startDateComponents = start
            }
        }
        item.isCompleted = true
        do {
            try store.save(item, commit: true)
            generation += 1
            reminders.removeAll { $0.id == id }
        } catch {
            failure = "Couldn't tick off “\(item.title ?? "that reminder")” in Reminders. Try it there."
        }
    }

    // MARK: Changes Claude makes (seam 31)

    /// Adds a reminder to a list; its identifier.
    func add(title: String, listID: String, due: ReminderDue?, notes: String? = nil, repeatRule: ReminderRepeat? = nil) throws -> String {
        guard let store else {
            let id = "claude-\(UUID().uuidString)"
            reminders.append(Reminder(id: id, title: title, listID: listID, due: due, repeatRule: repeatRule, notes: notes))
            return id
        }
        guard let list = store.calendar(withIdentifier: listID) else { throw ClaudeRefusal("That Reminders list is gone.") }
        let item = EKReminder(eventStore: store)
        item.title = title
        item.calendar = list
        item.dueDateComponents = due.map(Self.components)
        item.notes = notes
        item.recurrenceRules = repeatRule.map { [Self.rule($0)] }
        try save(item, store)
        // Listed now, so Claude can edit or tick it before the fetch lands.
        reminders.append(Self.reminder(item))
        return item.calendarItemIdentifier
    }

    /// A reminder's title, due date, notes ("" for none) and repeat (nil when
    /// only Reminders can describe it), open or done, and its list; nil when it's gone.
    func current(_ id: String) -> (edit: ReminderEdit, done: Bool, listID: String)? {
        guard let store else {
            if let open = reminders.first(where: { $0.id == id }) { return (Self.edit(open), false, open.listID) }
            return sampleDone[id].map { (Self.edit($0), true, $0.listID) }
        }
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        return (Self.edit(Self.reminder(item)), item.isCompleted, item.calendar.calendarIdentifier)
    }

    private static func edit(_ reminder: Reminder) -> ReminderEdit {
        var edit = ReminderEdit(title: reminder.title, due: reminder.due, notes: reminder.notes ?? "")
        if !reminder.repeats { edit.repeating = .never } else if let rule = reminder.repeatRule { edit.repeating = .rule(rule) }
        return edit
    }

    func edit(_ id: String, to edit: ReminderEdit) throws {
        guard let store else {
            guard let index = reminders.firstIndex(where: { $0.id == id }) else { throw Self.gone }
            reminders[index].title = edit.title
            reminders[index].due = edit.due
            if let notes = edit.notes { reminders[index].notes = notes.isEmpty ? nil : notes }
            if let repeating = edit.repeating {
                let old = reminders[index]
                reminders[index] = Reminder(
                    id: old.id, title: old.title, listID: old.listID, due: old.due,
                    repeatRule: repeating.repeatRule, notes: old.notes)
            }
            return
        }
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else { throw Self.gone }
        item.title = edit.title
        // Off before the due date goes: Reminders refuses a repeat with no due date.
        if let repeating = edit.repeating { item.recurrenceRules = repeating.repeatRule.map { [Self.rule($0)] } }
        item.dueDateComponents = edit.due.map(Self.components)
        if let notes = edit.notes { item.notes = notes.isEmpty ? nil : notes }
        // A start date after the new due date would keep it out of Today.
        if edit.due == nil { item.startDateComponents = nil }
        try save(item, store)
    }

    /// Ticks off or reopens a reminder, for Claude and for undoing it.
    func setDone(_ id: String, _ done: Bool) throws {
        guard let store else {
            // As Reminders does: a repeat moves on and leaves a done copy.
            let today = Day(.now, in: .current)
            if done, let index = reminders.firstIndex(where: { $0.id == id }) {
                let reminder = reminders[index]
                if reminder.repeats, let due = reminder.due {
                    let copy = "done-\(UUID().uuidString)"
                    completed.append(CompletedReminder(id: copy, title: reminder.title, listID: reminder.listID, day: today))
                    let rule = reminder.repeatRule
                    let days = rule.map { $0.every * ($0.frequency == .daily ? 1 : $0.frequency == .weekly ? 7 : $0.frequency == .monthly ? 30 : 365) } ?? 7
                    reminders[index].due = ReminderDue(day: Day(ordinal: due.day.ordinal + days), minute: due.minute)
                } else {
                    sampleDone[id] = reminders.remove(at: index)
                    completed.append(CompletedReminder(id: id, title: reminder.title, listID: reminder.listID, day: today))
                }
            } else if !done, let reminder = sampleDone.removeValue(forKey: id) {
                reminders.append(reminder)
                completed.removeAll { $0.id == id }
            } else {
                throw Self.gone
            }
            return
        }
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else { throw Self.gone }
        item.isCompleted = done
        try save(item, store)
    }

    /// Moves a reminder to another list.
    func move(_ id: String, toList listID: String) throws {
        guard let store else {
            guard let index = reminders.firstIndex(where: { $0.id == id }) else { throw Self.gone }
            reminders[index].listID = listID
            return
        }
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else { throw Self.gone }
        guard let list = store.calendar(withIdentifier: listID) else { throw ClaudeRefusal("That Reminders list is gone.") }
        item.calendar = list
        try save(item, store)
    }

    /// Removes a reminder: one Claude added, for undo, or one Claude deletes.
    func remove(_ id: String) throws {
        guard let store else {
            guard reminders.contains(where: { $0.id == id }) || sampleDone[id] != nil || completed.contains(where: { $0.id == id }) else { throw Self.gone }
            completed.removeAll { $0.id == id }
            reminders.removeAll { $0.id == id }
            sampleDone[id] = nil
            return
        }
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else { throw Self.gone }
        do {
            try store.remove(item, commit: true)
        } catch {
            throw ClaudeRefusal("Reminders didn't remove “\(item.title ?? "it")”: \(error.localizedDescription)")
        }
        refresh()
    }

    private func save(_ item: EKReminder, _ store: EKEventStore) throws {
        do {
            try store.save(item, commit: true)
        } catch {
            throw ClaudeRefusal("Reminders didn't save “\(item.title ?? "it")”: \(error.localizedDescription)")
        }
        refresh()
    }

    private static let gone = ClaudeRefusal("That reminder isn't in Reminders any more.")

    /// A due day, with a time in their zone for a timed one.
    nonisolated private static func components(_ due: ReminderDue) -> DateComponents {
        var parts = DateComponents(year: due.day.year, month: due.day.month, day: due.day.dayOfMonth)
        if let minute = due.minute {
            parts.hour = minute / 60
            parts.minute = minute % 60
            parts.timeZone = .current
        }
        return parts
    }

    func openReminders() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func access(_ status: EKAuthorizationStatus) -> Access {
        switch status {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    nonisolated private static func reminder(_ item: EKReminder) -> Reminder {
        let rules = item.recurrenceRules ?? []
        let daily = rules.contains { $0.frequency == .daily && $0.interval == 1 }
        let due = item.dueDateComponents.flatMap { ReminderDue($0, in: .current) }
        return Reminder(
            id: item.calendarItemIdentifier, title: item.title ?? "", listID: item.calendar.calendarIdentifier,
            due: due, repeatsDaily: daily, repeats: !rules.isEmpty,
            repeatRule: rules.count == 1 ? repeatRule(rules[0], due: due) : nil, notes: item.notes.flatMap { $0.isEmpty ? nil : $0 })
    }

    // EKWeekday counts from Sunday (1); Compass from Monday (0).
    nonisolated private static func weekday(_ day: EKWeekday) -> Int { (day.rawValue + 5) % 7 }
    nonisolated private static func ekWeekday(_ day: Int) -> EKWeekday { EKWeekday(rawValue: (day + 1) % 7 + 1)! }

    /// A rule Compass can describe; nil for one only Reminders can (the
    /// second Sunday, a count of times, several months).
    nonisolated private static func repeatRule(_ rule: EKRecurrenceRule, due: ReminderDue?) -> ReminderRepeat? {
        let frequency: ReminderRepeat.Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: return nil
        }
        let days = rule.daysOfTheWeek ?? []
        guard days.isEmpty || (frequency == .weekly && days.allSatisfy { $0.weekNumber == 0 }) else { return nil }
        // Reminders may name the due date's own day of the month; that's still plain monthly.
        let monthDays = rule.daysOfTheMonth?.map(\.intValue) ?? []
        guard monthDays.isEmpty || (frequency == .monthly && monthDays == [due?.day.dayOfMonth ?? -1]) else { return nil }
        guard (rule.monthsOfTheYear ?? []).isEmpty, (rule.weeksOfTheYear ?? []).isEmpty, (rule.daysOfTheYear ?? []).isEmpty,
            (rule.setPositions ?? []).isEmpty, rule.recurrenceEnd?.occurrenceCount ?? 0 == 0
        else { return nil }
        return ReminderRepeat(
            frequency: frequency, every: rule.interval, weekdays: Set(days.map { weekday($0.dayOfTheWeek) }),
            until: rule.recurrenceEnd?.endDate.map { Day($0, in: .current) })
    }

    nonisolated private static func rule(_ rule: ReminderRepeat) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency =
            switch rule.frequency {
            case .daily: .daily
            case .weekly: .weekly
            case .monthly: .monthly
            case .yearly: .yearly
            }
        let days = rule.weekdays.sorted().map { EKRecurrenceDayOfWeek(ekWeekday($0)) }
        // The end is inclusive: through the last minute of `until`.
        let end = rule.until.map { EKRecurrenceEnd(end: Day(ordinal: $0.ordinal + 1).startDate(in: .current).addingTimeInterval(-60)) }
        return EKRecurrenceRule(
            recurrenceWith: frequency, interval: rule.every, daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
    }

    /// Reminders in `listIDs` ticked off since `day`, read when asked (the
    /// screens keep only the last 90 days, for habits).
    func completed(since day: Day, in listIDs: Set<String>) async -> [CompletedReminder] {
        guard let store else { return completed.filter { listIDs.contains($0.listID) && $0.day >= day } }
        guard access == .granted else { return [] }
        let calendars = store.calendars(for: .reminder).filter { listIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForCompletedReminders(
            withCompletionDateStarting: day.startDate(in: .current),
            ending: nil, calendars: calendars)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: (found ?? []).compactMap(Self.completed).sorted { $0.day > $1.day })
            }
        }
    }

    nonisolated private static func completed(_ item: EKReminder) -> CompletedReminder? {
        guard let date = item.completionDate else { return nil }
        return CompletedReminder(
            id: item.calendarItemIdentifier, title: item.title ?? "",
            listID: item.calendar.calendarIdentifier, day: Day(date, in: .current))
    }
}

extension RemindersService {
    /// Made-up reminders around today, for renders and the demo. None of
    /// them are their.
    private static func sample(today: Day) -> ([ReminderList], [Reminder]) {
        let lists = [
            ReminderList(id: "week", title: "This Week"), ReminderList(id: "quarter", title: "This Quarter"),
            ReminderList(id: "inbox", title: "Inbox"), ReminderList(id: "long", title: "Long Term"),
            ReminderList(id: "living", title: "Living List"), ReminderList(id: "daily", title: "Repetitive Tasks"),
            ReminderList(id: "errands", title: "Admin"), ReminderList(id: "food", title: "Grocery")
        ]
        func on(_ offset: Int, at minute: Int? = nil) -> ReminderDue {
            ReminderDue(day: Day(ordinal: today.ordinal + offset), minute: minute)
        }
        let quarterEnd = Quarter(today).end.ordinal - today.ordinal
        let reminders = [
            Reminder(id: "1", title: "Return the library books", listID: "errands", due: on(-2)),
            Reminder(id: "2", title: "Pick up the dry cleaning", listID: "errands"),
            Reminder(id: "3", title: "Renew car registration", listID: "errands", due: on(20)),
            Reminder(id: "4", title: "Plan the weekend hike", listID: "week"),
            Reminder(id: "5", title: "Back up the laptop", listID: "week", due: on(-1)),
            Reminder(id: "6", title: "Water the plants", listID: "daily", due: on(0), repeatsDaily: true),
            Reminder(id: "7", title: "Read for 20 minutes", listID: "daily", due: on(0, at: 21 * 60), repeatsDaily: true),
            Reminder(id: "8", title: "Stretch", listID: "daily", due: on(-1), repeatsDaily: true),
            Reminder(id: "9", title: "Call an old friend", listID: "daily", due: on(0, at: 18 * 60), repeats: true),
            Reminder(id: "10", title: "Check in on a cousin", listID: "daily", due: on(9), repeats: true),
            Reminder(id: "11", title: "Look into a new bike", listID: "inbox"),
            Reminder(id: "12", title: "Oat milk", listID: "food", due: on(0)),
            // Linked to the sample Journal habit, so it shows there, not under Every day.
            Reminder(id: "13", title: "Journal", listID: "daily", due: on(0, at: 22 * 60), repeatsDaily: true),
            Reminder(id: "20", title: "$150K net worth by year-end", listID: "quarter", due: on(quarterEnd)),
            Reminder(id: "21", title: "Run a 10K", listID: "quarter", due: on(quarterEnd - 20)),
            Reminder(id: "22", title: "Book a pottery class", listID: "quarter", due: on(-3)),
            Reminder(id: "23", title: "Read six books", listID: "quarter"),
            Reminder(id: "30", title: "Book a holiday cottage", listID: "long", due: on(40)),
            Reminder(id: "31", title: "Learn to make bread", listID: "long"),
            Reminder(id: "32", title: "Sort out a will", listID: "long", due: on(3)),
            Reminder(id: "40", title: "Living List: See the northern lights", listID: "living"),
            Reminder(id: "41", title: "Learn to sail", listID: "living"),
            Reminder(id: "42", title: "Hike the Dolomites", listID: "living"),
            Reminder(id: "43", title: "Take a pottery class", listID: "living"),
            Reminder(id: "44", title: "Go to a silent retreat", listID: "living")
        ]
        return (lists, reminders)
    }

    private func completeSample(_ id: String) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        if reminders[index].repeatsDaily, let due = reminders[index].due {
            reminders[index].due = ReminderDue(day: Day(ordinal: Day(.now, in: .current).ordinal + 1), minute: due.minute)
        } else {
            reminders.remove(at: index)
        }
    }
}

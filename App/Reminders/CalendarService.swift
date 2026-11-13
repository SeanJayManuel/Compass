import AppKit
import Core
import EventKit
import Observation

/// This week's events, read live from Calendar through EventKit.
/// Nothing is kept: no records, no backup.
///
/// In the sandbox (every debug run: snapshots, the demo, perf) it holds fixed
/// sample events and never touches EventKit, so no run asks for access.
@Observable
final class CalendarService {
    private(set) var access: RemindersService.Access
    /// Sunday through the end of Saturday, from every calendar; hidden ones are
    /// left out where they're shown.
    private(set) var events: [CalendarEvent] = []
    private(set) var calendars: [ReminderList] = []
    /// Each calendar's colour, as they set it in Calendar.
    private(set) var colors: [String: NSColor] = [:]

    /// Nil in the sandbox.
    private let store: EKEventStore?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The sandbox's notes on events Claude added.
    @ObservationIgnored private var sampleNotes: [String: String] = [:]

    init(demo: Bool) {
        if demo {
            store = nil
            access = .granted
            (calendars, events) = Self.sample(today: Day(.now, in: .current))
            colors = ["home": .systemBlue, "work": .systemOrange, "compass": .systemPurple]
            return
        }
        let store = EKEventStore()
        self.store = store
        access = Self.access(EKEventStore.authorizationStatus(for: .event))
        let center = NotificationCenter.default
        observers = [
            // Any change in Calendar, here or synced from another device.
            center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            // Access changed in System Settings, or a new day began while Compass was in the background.
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
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        access = granted ? .granted : .denied
        store.reset()
        refresh()
    }

    private func recheckAccess() {
        guard let store else { return }
        let now = Self.access(EKEventStore.authorizationStatus(for: .event))
        if now != access {
            access = now
            store.reset()
            if now != .granted { events = []; calendars = [] }
        }
        refresh()
    }

    func refresh() {
        guard let store, access == .granted else { return }
        let found = store.calendars(for: .event)
        calendars = found.map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
        colors = Dictionary(found.map { ($0.calendarIdentifier, $0.color ?? .systemGray) }, uniquingKeysWith: { first, _ in first })
        let today = Day(.now, in: .current)
        let start = Week(today).start.startDate(in: .current)
        let end = Day(ordinal: Week(today).end.ordinal + 1).startDate(in: .current)
        events = fetch(store, from: start, to: end)
    }

    /// Events overlapping any range, from every calendar, for Claude. Read
    /// fresh each time; the sandbox's samples stand in for Calendar.
    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        guard let store else { return events.filter { $0.end > start && $0.start < end } }
        guard access == .granted else { return [] }
        return fetch(store, from: start, to: end)
    }

    private func fetch(_ store: EKEventStore, from start: Date, to end: Date) -> [CalendarEvent] {
        store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).map {
            CalendarEvent(
                id: $0.calendarItemIdentifier + "@\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "",
                calendarID: $0.calendar.calendarIdentifier, start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay)
        }
    }

    // MARK: Changes Claude makes (seam 31)

    /// Where Compass remembers the calendar it made, so one of theirs that
    /// happens to be called Compass is never taken over.
    static let compassCalendarKey = "calendar.compassCalendarID"

    /// The Compass calendar's identifier, if it's been made and still exists.
    var compassCalendarID: String? {
        guard let id = UserDefaults.standard.string(forKey: Self.compassCalendarKey) else { return nil }
        guard let store else { return calendars.contains { $0.id == id } ? id : nil }
        return store.calendar(withIdentifier: id) != nil ? id : nil
    }

    /// The Compass calendar, made the first time Claude adds an event: in
    /// the account new events go to (iCloud, usually), else on this Mac.
    func compassCalendar() throws -> String {
        if let id = compassCalendarID { return id }
        guard let store else {
            let id = "compass"
            calendars.append(ReminderList(id: id, title: ClaudeRules.calendarName))
            UserDefaults.standard.set(id, forKey: Self.compassCalendarKey)
            return id
        }
        guard access == .granted else { throw ClaudeRefusal("Compass can't use Calendar; they can allow it in the Life overview.") }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = ClaudeRules.calendarName
        guard
            let source = store.defaultCalendarForNewEvents?.source
                ?? store.sources.first(where: { $0.sourceType == .calDAV })
                ?? store.sources.first(where: { $0.sourceType == .local })
        else {
            throw ClaudeRefusal("Calendar has no account to add a Compass calendar to.")
        }
        calendar.source = source
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw ClaudeRefusal("Calendar didn't make the Compass calendar: \(error.localizedDescription)")
        }
        UserDefaults.standard.set(calendar.calendarIdentifier, forKey: Self.compassCalendarKey)
        refresh()
        return calendar.calendarIdentifier
    }

    /// An event by its identifier (or external identifier), as Claude sees it.
    /// An id naming one date of a repeating event (`ClaudeRules.occurrenceID`)
    /// finds that date, and comes back with the date's id.
    func event(_ id: String) -> (event: CalendarEvent, externalID: String?, notes: String?)? {
        let start = ClaudeRules.occurrence(id).start
        guard let store else {
            return sampleIndex(id).map { index in
                var found = events[index]
                if start != nil { found.id = ClaudeRules.occurrenceID(found.id, start: found.start) }
                return (found, nil, sampleNotes[events[index].id])
            }
        }
        guard let item = item(id, store) else { return nil }
        let eventID = start == nil ? item.calendarItemIdentifier : ClaudeRules.occurrenceID(item.calendarItemIdentifier, start: item.startDate)
        return (
            CalendarEvent(
                id: eventID, title: item.title ?? "", calendarID: item.calendar.calendarIdentifier,
                start: item.startDate, end: item.endDate, isAllDay: item.isAllDay), item.calendarItemExternalIdentifier, item.notes
        )
    }

    /// Whether Claude may change an event there: its calendar's name, whether
    /// it takes changes, and whether someone else organizes it.
    func access(_ id: String) -> EventAccess? {
        guard let store else {
            guard let event = event(id)?.event else { return nil }
            let title = calendars.first { $0.id == event.calendarID }?.title ?? ""
            return EventAccess(calendarTitle: title, allowsChanges: true, organizedBySomeoneElse: false)
        }
        guard let item = item(id, store) else { return nil }
        let invited = item.organizer.map { !$0.isCurrentUser } ?? false
        return EventAccess(
            calendarTitle: item.calendar.title, allowsChanges: item.calendar.allowsContentModifications,
            organizedBySomeoneElse: invited, hasGuests: item.hasAttendees)
    }

    /// Adds an event to the Compass calendar.
    func create(title: String, start: Date, end: Date, isAllDay: Bool, notes: String?) throws -> ClaudeEvent {
        let calendarID = try compassCalendar()
        guard let store else {
            let id = "claude-\(UUID().uuidString)"
            events.append(CalendarEvent(id: id, title: title, calendarID: calendarID, start: start, end: end, isAllDay: isAllDay))
            sampleNotes[id] = notes
            return ClaudeEvent(id: id, externalID: nil, title: title, start: start, end: end, isAllDay: isAllDay, notes: notes)
        }
        let item = EKEvent(eventStore: store)
        item.calendar = store.calendar(withIdentifier: calendarID)
        item.title = title
        item.startDate = start
        item.endDate = end
        item.isAllDay = isAllDay
        item.notes = notes
        try save(item, store)
        return ClaudeEvent(
            id: item.calendarItemIdentifier, externalID: item.calendarItemExternalIdentifier,
            title: title, start: item.startDate, end: item.endDate, isAllDay: isAllDay, notes: notes)
    }

    func move(_ id: String, start: Date, end: Date) throws {
        guard let store else {
            guard let index = sampleIndex(id) else { throw Self.gone }
            (events[index].start, events[index].end) = (start, end)
            return
        }
        guard let item = item(id, store) else { throw Self.gone }
        item.startDate = start
        item.endDate = end
        try save(item, store)
    }

    func edit(_ id: String, title: String, notes: String?) throws {
        guard let store else {
            guard let index = sampleIndex(id) else { throw Self.gone }
            events[index].title = title
            sampleNotes[events[index].id] = notes
            return
        }
        guard let item = item(id, store) else { throw Self.gone }
        item.title = title
        item.notes = notes
        try save(item, store)
    }

    func delete(_ id: String) throws {
        guard let store else {
            guard events.contains(where: { $0.id == id }) else { throw Self.gone }
            events.removeAll { $0.id == id }
            return
        }
        guard let item = item(id, store) else { throw Self.gone }
        do {
            try store.remove(item, span: .thisEvent, commit: true)
        } catch {
            throw ClaudeRefusal("Calendar didn't delete “\(item.title ?? "it")”: \(error.localizedDescription)")
        }
        refresh()
    }

    private func sampleIndex(_ id: String) -> Int? {
        let (itemID, start) = ClaudeRules.occurrence(id)
        return events.firstIndex { $0.id == id || ($0.id == itemID && (start == nil || $0.start == start)) }
    }

    /// The event, or with a date in its id, that date of a repeating one:
    /// every date shares the identifier, which alone finds the first.
    private func item(_ id: String, _ store: EKEventStore) -> EKEvent? {
        let (itemID, start) = ClaudeRules.occurrence(id)
        guard let start else {
            return (store.calendarItem(withIdentifier: id) as? EKEvent) ?? (store.calendarItems(withExternalIdentifier: id).first as? EKEvent)
        }
        let near = store.predicateForEvents(withStart: start.addingTimeInterval(-60), end: start.addingTimeInterval(60), calendars: nil)
        return store.events(matching: near).first {
            // Ids name whole seconds; a synced start can carry a fraction.
            ($0.calendarItemIdentifier == itemID || $0.calendarItemExternalIdentifier == itemID) && abs($0.startDate.timeIntervalSince(start)) < 1
        }
    }

    private func save(_ item: EKEvent, _ store: EKEventStore) throws {
        do {
            try store.save(item, span: .thisEvent, commit: true)
        } catch {
            throw ClaudeRefusal("Calendar didn't save “\(item.title ?? "it")”: \(error.localizedDescription)")
        }
        refresh()
    }

    private static let gone = ClaudeRefusal("That event isn't in Calendar any more.")

    func openCalendar() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func access(_ status: EKAuthorizationStatus) -> RemindersService.Access {
        switch status {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }
}

/// Which calendars the Life overview shows: all, until they hide some.
enum CalendarLists {
    static let hiddenKey = "calendar.hiddenCalendars"

    static func hidden(_ stored: String) -> Set<String> {
        Set(stored.split(separator: "\n").map(String.init))
    }

    static func store(_ hidden: Set<String>) -> String { hidden.sorted().joined(separator: "\n") }
}

extension CalendarService {
    /// Made-up events around today, for renders and the demo. None of them
    /// are their.
    private static func sample(today: Day) -> ([ReminderList], [CalendarEvent]) {
        let calendars = [ReminderList(id: "home", title: "Home"), ReminderList(id: "work", title: "Work")]
        func on(_ offset: Int, _ hour: Int, _ minute: Int = 0, for length: TimeInterval = 3600) -> (Date, Date) {
            let start = Day(ordinal: today.ordinal + offset).startDate(in: .current)
                .addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
            return (start, start.addingTimeInterval(length))
        }
        func event(_ id: String, _ title: String, _ time: (Date, Date), calendar: String = "home", allDay: Bool = false) -> CalendarEvent {
            CalendarEvent(id: id, title: title, calendarID: calendar, start: time.0, end: time.1, isAllDay: allDay)
        }
        let events = [
            event("1", "Dentist", on(0, 9, 30)),
            event("2", "Team planning", on(0, 14, for: 5400), calendar: "work"),
            event("3", "Dinner with friends", on(1, 19, for: 7200)),
            event("4", "Mum's birthday", on(2, 0, for: 86399), allDay: true),
            event("5", "Run club", on(2, 7)),
            event("6", "Farmers market", on(4, 10)),
            event("7", "Coffee with Sam", on(0, 15, for: 2700)),
            event("8", "Weekend away", on(4, 0, for: 2 * 86400 - 1), allDay: true),
            event("9", "Gym", on(-1, 7, 30))
        ]
        return (calendars, events)
    }
}

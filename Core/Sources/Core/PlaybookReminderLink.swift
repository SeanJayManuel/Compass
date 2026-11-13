import Foundation

/// The reminder a repeating Playbook entry shows as in Reminders, so it's on
/// their phone. Nil until Compass makes one (or finds the one carrying its link).
public enum PlaybookReminder: Hashable, Codable, Sendable {
    /// Its `calendarItemIdentifier`, and its `calendarItemExternalIdentifier`,
    /// which survives iCloud syncing.
    case linked(id: String, externalID: String)
    /// They deleted it in Reminders: not on their phone until they turn it back on.
    case off
}

/// A reminder carrying a Playbook link, or the one an entry is linked to, as
/// Reminders has it.
public struct PlaybookReminderState: Hashable, Sendable {
    public var id: String
    public var externalID: String
    /// The entry in its `compass://playbook/<id>` address; nil without one.
    public var entryID: UUID?
    public var title: String
    public var due: Day?
    /// The local day it was ticked off; nil while it's open.
    public var completedOn: Day?

    public init(id: String, externalID: String, entryID: UUID?, title: String, due: Day?, completedOn: Day? = nil) {
        self.id = id
        self.externalID = externalID
        self.entryID = entryID
        self.title = title
        self.due = due
        self.completedOn = completedOn
    }
}

/// Repeating Playbook entries as plain reminders in Reminders (seam 46). The
/// Playbook decides: each reminder is titled as its entry and due on its next
/// due day. A tick in Reminders records it done on the day it was ticked,
/// then the reminder reopens on the day after that. It doesn't use Reminders'
/// own repeat, which counts from the due day rather than from when it was done.
public enum PlaybookReminderLink {
    /// Whether a Reminders list is the one new ones go in, when they have it
    /// (Repetitive Tasks unless Settings names another), ignoring case and
    /// spaces around it.
    public static func isList(_ title: String, names: ReminderListNames = .saved) -> Bool { names.matches(.repeats, title) }
    /// How many days back ticked reminders are read for their links. One
    /// ticked longer ago is still found by its identifier.
    public static let lookback = 90

    public enum Action: Hashable, Sendable {
        case create(entry: UUID, title: String, due: Day)
        /// Sets its title and due day, reopening a ticked one.
        case update(id: String, title: String, due: Day, reopen: Bool)
        case delete(id: String)
    }

    public struct Plan: Hashable, Sendable {
        /// Only the entries that changed: done on a tick, linked, unlinked or turned off.
        public var entries: [PlaybookEntry]
        public var actions: [Action]
    }

    /// What to change to bring Reminders and the Playbook in step. `found`
    /// holds every reminder carrying a Playbook link and the ones entries are
    /// linked to; `gone` the linked ones Reminders says no longer exist. A
    /// linked reminder in neither is left alone: not found isn't deleted.
    public static func sync(
        _ entries: [PlaybookEntry], found: [PlaybookReminderState], gone: Set<String>,
        today: Day
    ) -> Plan {
        var changed: [PlaybookEntry] = []
        var actions: [Action] = []
        var kept: Set<String> = []
        var deleted: Set<String> = []
        func delete(_ id: String) { if deleted.insert(id).inserted { actions.append(.delete(id: id)) } }

        for entry in entries {
            var updated = entry
            let mine = found.filter { state in
                if case .linked(let id, let externalID) = entry.reminder, state.id == id || state.externalID == externalID { return true }
                return state.entryID == entry.id
            }
            if entry.repeatEveryDays == nil {
                // Compass deletes it, so it's forgotten rather than turned off.
                if case .linked(let id, _) = entry.reminder, mine.isEmpty { delete(id) }
                mine.forEach { delete($0.id) }
                updated.reminder = nil
            } else if entry.reminder == .off {
                // They deleted it; whatever carries its link now is their to keep.
                kept.formUnion(mine.map(\.id))
            } else if let reminder = linkedFirst(mine, entry.reminder) {
                kept.insert(reminder.id)
                updated.reminder = .linked(id: reminder.id, externalID: reminder.externalID)
                if let done = reminder.completedOn {
                    let day = min(done, today)
                    if entry.lastDone.map({ day > $0 }) ?? true { updated = Playbook.markDone(updated, on: day) }
                }
                let due = Playbook.nextDue(updated, today: today)!
                if reminder.completedOn != nil || reminder.title != entry.title || reminder.due != due {
                    actions.append(.update(id: reminder.id, title: entry.title, due: due, reopen: reminder.completedOn != nil))
                }
            } else if case .linked(let id, _) = entry.reminder {
                if gone.contains(id) { updated.reminder = .off }
            } else {
                actions.append(.create(entry: entry.id, title: entry.title, due: Playbook.nextDue(entry, today: today)!))
            }
            if updated != entry { changed.append(updated) }
        }
        // Reminders whose entry is gone, doesn't repeat, or already has one.
        for state in found where state.entryID != nil && !kept.contains(state.id) { delete(state.id) }
        return Plan(entries: changed, actions: actions)
    }

    /// The reminders entries stand in for, to leave out of the agenda.
    public static func linkedIDs(_ entries: [PlaybookEntry]) -> Set<String> {
        Set(
            entries.compactMap { entry in
                if case .linked(let id, _) = entry.reminder { id } else { nil }
            })
    }

    /// The link put on each reminder, so Compass finds it again if Reminders
    /// gives it new identifiers.
    public static func address(for entryID: UUID) -> URL {
        URL(string: "compass://playbook/\(entryID.uuidString)")!
    }

    public static func entryID(in url: URL) -> UUID? {
        guard url.scheme == "compass", url.host == "playbook" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    /// The one it's linked to, else the first carrying its link.
    private static func linkedFirst(_ mine: [PlaybookReminderState], _ link: PlaybookReminder?) -> PlaybookReminderState? {
        if case .linked(let id, let externalID) = link,
            let same = mine.first(where: { $0.id == id }) ?? mine.first(where: { $0.externalID == externalID })
        {
            return same
        }
        return mine.first
    }
}

extension PlaybookEntry {
    /// The entry as they wrote it, leaving out the reminder the sync keeps.
    var withoutReminder: PlaybookEntry {
        var entry = self
        entry.reminder = nil
        return entry
    }
}

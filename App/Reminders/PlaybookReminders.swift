import Core
import EventKit
import Foundation
import SwiftData

/// Keeps each repeating Playbook entry as a plain reminder in Reminders, so
/// it's on their phone (seam 46; the rules are `PlaybookReminderLink`). Runs
/// whenever Reminders has been read (at launch and on every change there)
/// and after any Playbook save, Claude's included. Never in the sandbox,
/// where Reminders isn't read.
@MainActor
final class PlaybookReminders {
    private let context: ModelContext
    private let reminders: RemindersService
    private var observer: NSObjectProtocol?
    private var running = false
    private var again = false

    init(container: ModelContainer, reminders: RemindersService) {
        context = container.mainContext
        self.reminders = reminders
        guard reminders.store != nil else { return }
        reminders.onLoad = { [weak self] in self?.sync() }
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
            let entities = ModelContext.savedEntityNames(in: note)
            guard entities?.contains("PlaybookEntryRecord") ?? true else { return }
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    /// One pass; a call while one runs asks for another after it.
    func sync() {
        guard !running else { again = true; return }
        running = true
        Task {
            await pass()
            running = false
            if again { again = false; sync() }
        }
    }

    private func pass() async {
        guard let events = reminders.store, reminders.access == .granted, reminders.loaded else { return }
        let store = CompassStore(context: context)
        guard let entries = try? store.playbook() else { return }
        let today = Day(.now, in: .current)
        // Every reminder carrying a Playbook link: open, or ticked lately.
        let since = Calendar.current.date(byAdding: .day, value: 1 - PlaybookReminderLink.lookback, to: Calendar.current.startOfDay(for: .now))
        var found =
            await Self.fetch(events, events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
            + Self.fetch(events, events.predicateForCompletedReminders(withCompletionDateStarting: since, ending: nil, calendars: nil))
        // The ones entries are linked to, wherever they are now; gone only
        // when Reminders has neither identifier.
        var gone: Set<String> = []
        for entry in entries {
            guard case .linked(let id, let externalID) = entry.reminder,
                !found.contains(where: { $0.id == id || $0.externalID == externalID })
            else { continue }
            let item =
                events.calendarItem(withIdentifier: id) as? EKReminder
                ?? (externalID.isEmpty ? nil : events.calendarItems(withExternalIdentifier: externalID).compactMap { $0 as? EKReminder }.first)
            if let item { found.append(Self.state(item)) } else { gone.insert(id) }
        }
        // Every one missing at once is Reminders not answering (an account
        // signing back in, say), not them deleting them all.
        let linked = PlaybookReminderLink.linkedIDs(entries)
        if linked.count > 1, gone == linked { gone = [] }
        // The Playbook may have changed while Reminders was read.
        guard (try? store.playbook()) == entries else { again = true; return }
        let plan = PlaybookReminderLink.sync(entries, found: found, gone: gone, today: today)
        for entry in plan.entries {
            do { try store.save(entry) } catch {
                storeLog.error("Couldn't save what Reminders changed on a Playbook entry: \(error.localizedDescription, privacy: .public)")
            }
        }
        for action in plan.actions { apply(action, events, store) }
    }

    private func apply(_ action: PlaybookReminderLink.Action, _ events: EKEventStore, _ store: CompassStore) {
        switch action {
        case .create(let entryID, let title, let due):
            let item = EKReminder(eventStore: events)
            item.title = title
            item.calendar =
                events.calendars(for: .reminder).first { PlaybookReminderLink.isList($0.title) }
                ?? events.defaultCalendarForNewReminders()
            item.dueDateComponents = Self.components(due)
            item.url = PlaybookReminderLink.address(for: entryID)
            guard (try? events.save(item, commit: true)) != nil,
                var entry = (try? store.playbook())?.first(where: { $0.id == entryID })
            else { return }
            entry.reminder = .linked(id: item.calendarItemIdentifier, externalID: item.calendarItemExternalIdentifier ?? "")
            do { try store.save(entry) } catch {
                // Unlinked, the next pass would make another: take this one back.
                storeLog.error("Couldn't save a Playbook entry's reminder link: \(error.localizedDescription, privacy: .public)")
                try? events.remove(item, commit: true)
            }
        case .update(let id, let title, let due, let reopen):
            guard let item = events.calendarItem(withIdentifier: id) as? EKReminder else { return }
            item.title = title
            item.dueDateComponents = Self.components(due)
            if reopen { item.isCompleted = false }
            try? events.save(item, commit: true)
        case .delete(let id):
            guard let item = events.calendarItem(withIdentifier: id) as? EKReminder else { return }
            try? events.remove(item, commit: true)
        }
    }

    /// All day: the Playbook only knows days.
    private static func components(_ day: Day) -> DateComponents {
        DateComponents(year: day.year, month: day.month, day: day.dayOfMonth)
    }

    /// Reminders carrying a Playbook link, as plain values: they're handed
    /// over off the main thread.
    nonisolated private static func fetch(_ events: EKEventStore, _ predicate: NSPredicate) async -> [PlaybookReminderState] {
        await withCheckedContinuation { continuation in
            events.fetchReminders(matching: predicate) { @Sendable found in
                continuation.resume(returning: (found ?? []).filter { $0.url.flatMap(PlaybookReminderLink.entryID) != nil }.map(state))
            }
        }
    }

    nonisolated private static func state(_ item: EKReminder) -> PlaybookReminderState {
        PlaybookReminderState(
            id: item.calendarItemIdentifier, externalID: item.calendarItemExternalIdentifier ?? "",
            entryID: item.url.flatMap(PlaybookReminderLink.entryID), title: item.title ?? "",
            due: item.dueDateComponents.flatMap { parts in
                parts.year.flatMap { year in parts.month.flatMap { month in parts.day.map { Day(year: year, month: month, day: $0) } } }
            },
            completedOn: item.isCompleted ? item.completionDate.map { Day($0, in: .current) } ?? Day(.now, in: .current) : nil)
    }
}

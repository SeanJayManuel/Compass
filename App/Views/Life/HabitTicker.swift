import Core
import SwiftData
import SwiftUI

/// Ticks and unticks habits' days for the Life overview and the menu bar
/// panel, and carries ticks made in Reminders over. Ticking today ticks off its linked reminder after a moment, if it's
/// still to do then; unticking before that leaves Reminders alone. One for
/// the app, so a tick in one place and an untick in the other cancel.
@MainActor @Observable final class HabitTicker {
    private let reminders: RemindersService
    /// Linked reminders waiting to be ticked off, by habit.
    @ObservationIgnored private var pending: [UUID: Task<Void, Never>] = [:]

    init(reminders: RemindersService) {
        self.reminders = reminders
    }

    func toggle(_ habit: Habit, on day: Day, today: Day, context: ModelContext) {
        let store = CompassStore(context: context)
        let result = HabitReminderLink.toggle(habit, on: day, reminders: reminders.reminders, today: today)
        guard SaveFailures.shared.attempt({ try store.save(result.habit) }) else { return }
        pending.removeValue(forKey: habit.id)?.cancel()
        guard day == today, habit.reminder != nil, result.habit.checkIns.contains(today) else { return }
        pending[habit.id] = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            pending[habit.id] = nil
            // Read again now: the reminders may have loaded since the click.
            guard let current = (try? store.habits())?.first(where: { $0.id == habit.id }),
                let completion = HabitReminderLink.completion(for: current, reminders: reminders.reminders, today: today)
            else { return }
            reminders.complete(completion.id, moveToToday: completion.moveToToday)
        }
    }

    /// Brings ticks made in Reminders over to their habits, and makes a habit
    /// for each daily repeat that has none, once both the open and the done
    /// reminders have been read.
    func carryOver(context: ModelContext) {
        guard reminders.access == .granted, reminders.loaded else { return }
        let store = CompassStore(context: context)
        // Read from the store, not a query: two changes landing together
        // would otherwise both see no habit yet and make it twice.
        guard let habits = try? store.habits() else { return }
        for habit in HabitReminderLink.newHabits(
            for: reminders.reminders, habits: habits,
            completed: reminders.completed, today: Day(.now, in: .current))
        {
            do { try store.save(habit) } catch { storeLog.error("Couldn't save a habit for a daily reminder: \(error.localizedDescription, privacy: .public)") }
        }
        for habit in habits where habit.reminder != nil {
            let carried = HabitReminderLink.carryOver(
                habit, reminders: reminders.reminders,
                completed: reminders.completed, today: Day(.now, in: .current))
            if carried != habit {
                do { try store.save(carried) } catch {
                    storeLog.error("Couldn't save ticks carried from Reminders: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

import Core
import SwiftUI

/// Which Reminders lists the Life overview leaves out, saved as their
/// identifiers one per line. Unset until they choose: then shopping lists.
enum RemindersLists {
    static let hiddenKey = "reminders.hiddenLists"

    static func hidden(_ stored: String?, lists: [ReminderList]) -> Set<String> {
        guard let stored else { return ReminderAgenda.hiddenByDefault(lists) }
        return Set(stored.split(separator: "\n").map(String.init))
    }

    static func store(_ hidden: Set<String>) -> String { hidden.sorted().joined(separator: "\n") }
}

extension ReminderAgenda {
    /// The agenda as the Life overview reads it: hidden lists left out, and
    /// reminders a habit or the Playbook stands in for. Nil without access.
    @MainActor static func life(
        _ service: RemindersService, habits: [Habit], playbook: [PlaybookEntry],
        today: Day
    ) -> ReminderAgenda? {
        guard service.access == .granted else { return nil }
        let hidden = RemindersLists.hidden(UserDefaults.standard.string(forKey: RemindersLists.hiddenKey), lists: service.lists)
        return ReminderAgenda(
            reminders: service.reminders, lists: service.lists, hidden: hidden,
            linked: HabitReminderLink.linkedIDs(habits, reminders: service.reminders)
                .union(PlaybookReminderLink.linkedIDs(playbook)), today: today)
    }
}

/// What's to do this week from Reminders: anything due by Sunday (overdue
/// first) and the This Week list, then admin, then any daily repeat still
/// to do today that no habit stands in for. Each can be ticked off here.
struct ToDoGlance: View {
    let today: Day
    /// Nil until Compass can see Reminders.
    let agenda: ReminderAgenda?
    @Environment(RemindersService.self) private var service

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            GlanceHeader(title: "To do", link: "Reminders") { service.openReminders() }
            switch service.access {
            case .notAsked:
                RemindersNote("See what's to do this week, your quarter and your lists from Reminders, and tick things off here.")
                Button("Show Reminders") { Task { await service.requestAccess() } }
            case .denied:
                RemindersNote("Compass can't see your reminders. You can turn that on in System Settings, under Privacy & Security.")
                Button("Open Privacy Settings") { service.openPrivacySettings() }
            case .granted:
                if let agenda { content(agenda) }
            }
            if let failure = service.failure {
                Text(failure).font(Typeface.detail).foregroundStyle(Palette.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: Spacing.m)
    }

    @ViewBuilder private func content(_ agenda: ReminderAgenda) -> some View {
        let listNames = Dictionary(service.lists.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let weekList = Set(service.lists.filter { ReminderListNames.saved.matches(.week, $0.title) }.map(\.id))
        if agenda.thisWeek.isEmpty && agenda.everyDay.isEmpty && agenda.admin.isEmpty {
            RemindersNote("Nothing to do this week.")
        }
        // Headed only when another section follows, so a lone list doesn't repeat the card's title.
        if !agenda.thisWeek.isEmpty {
            ReminderSection(
                title: "This week", items: agenda.thisWeek,
                headed: !agenda.admin.isEmpty || !agenda.everyDay.isEmpty
            ) { reminder in
                // A reminder from another list says where it's from.
                ReminderRow(
                    reminder: reminder, today: today, weekly: true,
                    list: weekList.contains(reminder.listID) ? nil : listNames[reminder.listID])
            }
        }
        if !agenda.admin.isEmpty {
            ReminderSection(title: "Admin", items: agenda.admin) { reminder in
                ReminderRow(reminder: reminder, today: today, weekly: true)
            }
        }
        if !agenda.everyDay.isEmpty {
            ReminderSection(title: "Every day", items: agenda.everyDay, flow: true) { reminder in
                ReminderChip(reminder: reminder, title: reminder.title, filled: true)
            }
        }
        if agenda.inbox > 0 {
            Text(agenda.inbox == 1 ? "1 in your inbox" : "\(agenda.inbox) in your inbox")
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
        }
    }
}

/// A run of reminders under a small heading with its count, all of them.
/// Rows are ruled apart; chips (`flow`) wrap.
struct ReminderSection<Item: View>: View {
    let title: String
    let items: [Reminder]
    var headed = true
    var flow = false
    @ViewBuilder let item: (Reminder) -> Item

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if headed {
                HStack(spacing: Spacing.xs) {
                    Text(title).font(Typeface.detail.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text("\(items.count)").font(Typeface.detail).monospacedDigit().foregroundStyle(Palette.inkSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            if flow {
                FlowRow(spacing: Spacing.s, lineSpacing: Spacing.s) {
                    ForEach(items) { item($0) }
                }
                .padding(.top, Spacing.xs)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, reminder in
                    if index > 0 { Rule() }
                    item(reminder)
                }
            }
        }
        .padding(.top, Spacing.s)
    }
}

/// A reminder to tick off: its title, the list it's from when that says
/// something, and when it's due. `trailing` sits under the title, like a
/// quarter goal's bar; `actions` fill its context menu.
struct ReminderRow<Trailing: View, Actions: View>: View {
    let reminder: Reminder
    let today: Day
    /// This week's reminders say a weekday and time; later ones a date.
    var weekly = false
    var title: String?
    var list: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var actions: () -> Actions
    @Environment(RemindersService.self) private var service
    @State private var tick = PendingTick()

    var body: some View {
        let ticked = tick.isPending
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Button {
                tick.toggle { service.complete(reminder.id) }
            } label: {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(Typeface.body)
                    .foregroundStyle(ticked ? Palette.needle : Palette.inkSecondary)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help(ticked ? "Click again to keep it open" : "Mark as done in Reminders")
            .accessibilityLabel(ticked ? "Undo: \(title ?? reminder.title)" : "Done: \(title ?? reminder.title)")
            VStack(alignment: .leading, spacing: 1) {
                Text(title ?? reminder.title).font(Typeface.body)
                    .foregroundStyle(ticked ? Palette.inkSecondary : Palette.ink)
                    .strikethrough(ticked, color: Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)  // the tick button already says it
                if let list { Text(list).font(Typeface.detail).foregroundStyle(Palette.inkSecondary).lineLimit(1) }
                trailing()
            }
            Spacer(minLength: Spacing.s)
            if let when = ReminderWhen.text(reminder, today: today, weekly: weekly) {
                when.font(Typeface.detail).monospacedDigit().lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(.rect)
        .contextMenu { actions() }
        .accessibilityElement(children: .combine)
    }
}

extension ReminderRow where Trailing == EmptyView, Actions == EmptyView {
    init(reminder: Reminder, today: Day, weekly: Bool = false, title: String? = nil, list: String? = nil) {
        self.init(
            reminder: reminder, today: today, weekly: weekly, title: title, list: list,
            trailing: { EmptyView() }, actions: { EmptyView() })
    }
}

/// A reminder as a small capsule to tick: the daily repeats (`filled`), and
/// the living list, outlined, since it's for doing someday, not today.
struct ReminderChip: View {
    let reminder: Reminder
    let title: String
    var filled = false
    @Environment(RemindersService.self) private var service
    @State private var tick = PendingTick()

    var body: some View {
        let ticked = tick.isPending
        Button {
            tick.toggle { service.complete(reminder.id) }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(ticked ? Palette.needle : Palette.inkSecondary)
                    .accessibilityHidden(true)
                Text(title).foregroundStyle(ticked ? Palette.inkSecondary : Palette.ink)
                    .strikethrough(ticked, color: Palette.inkSecondary)
                    .lineLimit(1)
            }
            .font(Typeface.detail)
            .padding(.vertical, Spacing.xs)
            .padding(.horizontal, Spacing.s)
            .background {
                if filled {
                    Capsule().fill(Palette.needleWash.opacity(ticked ? 0.5 : 1))
                } else {
                    Capsule().strokeBorder(Palette.rule, lineWidth: 1)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(ticked ? "Click again to keep it open" : "Mark as done in Reminders")
        .accessibilityLabel(ticked ? "Undo: \(title)" : "Done: \(title)")
    }
}

/// A tick that saves to Reminders after a moment: a second click before
/// then takes it back.
@MainActor @Observable
final class PendingTick {
    private var task: Task<Void, Never>?

    var isPending: Bool { task != nil }

    func toggle(save: @escaping @MainActor () -> Void) {
        if let task {
            task.cancel()
            self.task = nil
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.change) {
                save()
                self?.task = nil
            }
        }
    }
}

/// A line of quieter text inside a Reminders card.
struct RemindersNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Typeface.body).foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum ReminderWhen {
    /// "Overdue · Wed", "Today, 3 PM", "Tomorrow", "Sat"; later ones by date,
    /// and a ↻ before one that repeats. An undated one says nothing.
    static func text(_ reminder: Reminder, today: Day, weekly: Bool) -> Text? {
        guard let due = reminder.due else { return nil }
        let repeats =
            reminder.repeats
            ? Text("\(Image(systemName: "arrow.clockwise")) ").foregroundStyle(Palette.inkSecondary)
            : Text(verbatim: "")
        let date = due.day.startDate(in: .current)
        let weekday = date.formatted(.dateTime.weekday(.abbreviated))
        if due.day < today {
            let label = due.day.ordinal >= today.ordinal - 6 ? weekday : date.formatted(.dateTime.month(.abbreviated).day())
            return Text("\(repeats)\(Text("Overdue").foregroundStyle(Palette.attention)) · \(label)").foregroundStyle(Palette.inkSecondary)
        }
        let time = due.minute.map { minute in
            (Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: date) ?? date)
                .formatted(date: .omitted, time: .shortened)
        }
        let inWeek = due.day <= Week(today).end
        let day: String =
            if due.day == today { "Today" } else if due.day.ordinal == today.ordinal + 1 { "Tomorrow" } else if weekly && inWeek { weekday } else {
                date.formatted(.dateTime.month(.abbreviated).day())
            }
        let label = [day, weekly && inWeek ? time : nil].compactMap { $0 }.joined(separator: ", ")
        return Text("\(repeats)\(label)").foregroundStyle(Palette.inkSecondary)
    }
}

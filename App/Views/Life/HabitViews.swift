import Core
import SwiftData
import SwiftUI

/// One habit: a week's days to tick (this week, or an earlier one stepped
/// back to for a day that was missed), how many are done and the run of
/// weeks hit, in words. The Habits screen has the history.
struct HabitRow: View {
    let habit: Habit
    let today: Day
    let update: (Habit) -> Void
    /// Ticks or unticks a day; a linked reminder may tick off with it.
    let toggle: (Habit, Day) -> Void
    let edit: (Habit) -> Void
    /// The week whose days are shown; nil for this week.
    @State private var shown: Week?
    @Environment(\.rowDensity) private var density

    private static let dayLetters = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        let current = Week(today)
        // Back as far as the week it started, never past this week.
        let first = min(Week(habit.startedOn), current)
        let week = min(max(shown ?? current, first), current)
        let done = Habits.done(habit, in: week)
        let streak = Habits.streak(habit, today: today)
        let scale = TextSize.current.scale
        let statusText = status(done: done, week: week, isCurrent: week == current, streak: streak)
        let days = HStack(spacing: 6) {
            // Kept but hidden for a habit new this week, so every row's days line up.
            Button("Previous Week", systemImage: "chevron.left") { shown = week.previous }
                .disabled(week <= first)
                .help("Show the week before, to tick a day that was missed")
                .opacity(first < current ? 1 : 0)
                .accessibilityHidden(first >= current)
            ForEach(0..<7, id: \.self) { offset in
                dayButton(Day(ordinal: week.start.ordinal + offset), letter: Self.dayLetters[offset], scale: scale)
            }
            Button("Next Week", systemImage: "chevron.right") { shown = week.next == current ? nil : week.next }
                .disabled(week >= current)
                .opacity(first < current ? 1 : 0)
                .accessibilityHidden(first >= current)
        }
        .labelStyle(.iconOnly)
        // Not `linkButton()`: its underline would run through the day letters.
        .buttonStyle(.borderless).tint(Palette.needleText)
        .font(Typeface.detail)

        Group {
            if density == .compact {
                // Too narrow for the days beside the text: they take their own line.
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        titleLine
                        Spacer(minLength: Spacing.s)
                        actionsMenu
                    }
                    statusText.font(Typeface.detail).fixedSize(horizontal: false, vertical: true)
                    days.padding(.top, Spacing.xs)
                }
            } else {
                HStack(alignment: .center, spacing: Spacing.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        titleLine
                        // One run of text, so it wraps beside the days instead of clipping.
                        statusText.font(Typeface.detail).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Spacing.s)
                    days
                    actionsMenu
                }
            }
        }
        .padding(.vertical, Spacing.s)
        .contentShape(.rect)
        .contextMenu { actions }
    }

    /// The title, and a bell when a daily reminder is linked.
    private var titleLine: some View {
        let bell =
            habit.reminder == nil
            ? Text(verbatim: "")
            : Text("  \(Image(systemName: "bell"))").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
        return HStack(spacing: Spacing.s) {
            RowMark(text: habit.title, symbol: HabitIcon.symbol(for: habit.title))
            Text("\(Text(habit.title).font(Typeface.body).foregroundStyle(Palette.ink))\(bell)")
        }
        .fixedSize(horizontal: false, vertical: true)
        .help(habit.reminder.map { "Linked to “\($0.title)” in Reminders: ticking one ticks the other" } ?? "")
        .accessibilityValue(habit.reminder.map { "Linked to the reminder \($0.title)" } ?? "")
    }

    private var actionsMenu: some View {
        RowActionsMenu(label: "Actions for \(habit.title)") { actions }
    }

    /// The row's actions, in its context menu and its `…` menu alike.
    @ViewBuilder private var actions: some View {
        Button("Edit Habit…") { edit(habit) }
        Button("Stop Tracking") {
            var archived = habit
            archived.archived = true
            update(archived)
        }
    }

    private func dayButton(_ day: Day, letter: String, scale: CGFloat) -> some View {
        let checked = habit.checkIns.contains(day)
        // Days still to come can't be ticked, nor days before the week it
        // started (a stray tick from before can still be undone).
        let open = Habits.canCheckIn(habit, on: day, today: today)
        let beforeStart = day < Week(habit.startedOn).start
        return Button {
            toggle(habit, day)
        } label: {
            Text(letter)
                .font(.system(size: 11 * scale, weight: .semibold))
                // Done is green, as on the Habits grids; the accent ring marks today.
                .foregroundStyle(
                    checked
                        ? Palette.label(light: StatusHue.onPace.light, dark: StatusHue.onPace.dark)
                        : (day == today ? Palette.ink : Palette.inkSecondary)
                )
                .frame(width: 26 * scale, height: 26 * scale)
                .background(checked ? Palette.onPace : Palette.progressTrack.opacity(open ? 1 : 0.4), in: .circle)
                .overlay { if day == today && !checked { Circle().stroke(Palette.needle, lineWidth: 1.5) } }
        }
        .buttonStyle(.plain)
        .disabled(!open)
        .help(beforeStart && !open ? "Before this habit starts. To count it, change the start date in Edit Habit." : "")
        .accessibilityLabel(day.startDate(in: .current).formatted(.dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityValue(checked ? "Done" : "Not done")
    }

    private func status(done: Int, week: Week, isCurrent: Bool, streak: Int) -> Text {
        let when =
            isCurrent
            ? "this week"
            : "the week of \(week.start.startDate(in: .current).formatted(.dateTime.month(.abbreviated).day()))"
        let count = Text("\(done) of \(habit.perWeek) \(when)")
            .foregroundStyle(done >= habit.perWeek ? Palette.onPace : Palette.inkSecondary)
        // What this week still takes, for the current week only: "2 more, 4 days left".
        // Not said when the target's met, or when no day of this week can be ticked.
        let left = Habits.stillToDo(habit, today: today)
        let toGo =
            isCurrent && left.needed > 0 && left.daysLeft > 0
            ? Text(" · \(left.needed) more, \(left.daysLeft) \(left.daysLeft == 1 ? "day" : "days") left")
                .foregroundStyle(Palette.inkSecondary)
            : Text(verbatim: "")
        let run = streak > 1 ? Text(" · \(streak) weeks in a row").foregroundStyle(Palette.inkSecondary) : Text(verbatim: "")
        return Text("\(count)\(toGo)\(run)")
    }
}

struct HabitEditor: View {
    /// Every habit, so a reminder already linked to another isn't offered.
    let habits: [Habit]
    @Environment(\.modelContext) private var context
    @Environment(RemindersService.self) private var reminders
    @Environment(\.dismiss) private var dismiss
    @State private var habit: Habit

    init(habit: Habit, habits: [Habit]) {
        self.habits = habits
        _habit = State(initialValue: habit)
    }

    var body: some View {
        Form {
            TextField("Habit", text: $habit.title, prompt: Text("Work out"))
            Stepper("\(habit.perWeek) \(habit.perWeek == 1 ? "time" : "times") a week", value: $habit.perWeek, in: 1...7)
            // Not limited to today: a habit planned for next quarter starts then.
            DatePicker(
                "Started",
                selection: Binding(
                    get: { habit.startedOn.startDate(in: .current) },
                    set: { habit.startedOn = Day($0, in: .current) }
                ), displayedComponents: .date)
            Text("Weeks before it started don't count. Any day of its first week can be ticked.")
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            if reminders.access == .granted {
                reminderPicker
            } else {
                Text("To link a daily reminder to this habit, let Compass see Reminders from the To do card on the Life overview.")
                    .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var saved = habit
                    saved.title = habit.title.trimmingCharacters(in: .whitespaces)
                    try? CompassStore(context: context).save(saved)
                    dismiss()
                }
                .disabled(habit.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// A daily repeat in Reminders that prompts this habit. Linked, ticking
    /// one ticks the other, and it leaves Every day.
    @ViewBuilder private var reminderPicker: some View {
        let options = HabitReminderLink.candidates(for: habit, among: habits, reminders: reminders.reminders)
        let current = habit.reminder.flatMap { HabitReminderLink.find($0, in: reminders.reminders) }
        let missing = habit.reminder != nil && current == nil
        Picker(
            "Reminder",
            selection: Binding<String?>(
                get: { missing ? Self.missing : current?.id },
                set: { id in
                    guard id != Self.missing else { return }
                    guard let chosen = options.first(where: { $0.id == id }) else { habit.reminder = nil; return }
                    if chosen.id != current?.id {
                        habit.reminder = HabitReminder(id: chosen.id, title: chosen.title, listID: chosen.listID)
                    }
                }
            )
        ) {
            Text("None").tag(String?.none)
            if missing, let link = habit.reminder {
                Text("\(link.title) (not found)").tag(String?.some(Self.missing))
            }
            ForEach(options) { Text($0.title).tag(String?.some($0.id)) }
        }
        Text(
            missing
                ? "Its reminder isn't in Reminders any more. Choose another, or None."
                : "A daily reminder that prompts this habit. Ticking either one ticks the other, and the reminder moves here from Every day."
        )
        .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let missing = "missing"
}

/// One habit on the Life overview, as the draft: its name and icon, how
/// often and how many of the last 14 days, the 14 days as squares (green
/// when done; click one that can be ticked to tick it), and a check for today.
struct HabitStripRow: View {
    let habit: Habit
    let today: Day
    let update: (Habit) -> Void
    let toggle: (Habit, Day) -> Void
    let edit: (Habit) -> Void

    var body: some View {
        let scale = TextSize.current.scale
        let days = (0..<14).map { Day(ordinal: today.ordinal - 13 + $0) }
        let done = Set(habit.checkIns)
        let count = days.filter(done.contains).count
        let checked = done.contains(today)
        HStack(spacing: Spacing.s) {
            RowMark(text: habit.title, symbol: HabitIcon.symbol(for: habit.title))
            VStack(alignment: .leading, spacing: 1) {
                Text(habit.title).font(Typeface.body).foregroundStyle(Palette.ink).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(habit.perWeek >= 7 ? "daily" : "\(habit.perWeek) a week") · \(count) of 14 days")
                    .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: Spacing.s)
            HStack(spacing: 3) {
                ForEach(days, id: \.ordinal) { day in
                    let on = done.contains(day)
                    Button {
                        toggle(habit, day)
                    } label: {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(on ? Palette.onPace : Palette.progressTrack)
                            .frame(width: 9 * scale, height: 9 * scale)
                            .overlay { if day == today { RoundedRectangle(cornerRadius: 2).strokeBorder(Palette.inkSecondary, lineWidth: 1) } }
                    }
                    .buttonStyle(.plain)
                    .disabled(!Habits.canCheckIn(habit, on: day, today: today))
                    .help(day.startDate(in: .current).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + (on ? ": done" : ""))
                    .accessibilityLabel(day.startDate(in: .current).formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .accessibilityValue(on ? "Done" : "Not done")
                }
            }
            Button {
                toggle(habit, today)
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundStyle(checked ? Palette.label(light: StatusHue.onPace.light, dark: StatusHue.onPace.dark) : Palette.inkSecondary)
                    .frame(width: 26 * scale, height: 26 * scale)
                    .background(checked ? Palette.onPace : .clear, in: .circle)
                    .overlay { if !checked { Circle().strokeBorder(Palette.rule, lineWidth: 1) } }
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(!Habits.canCheckIn(habit, on: today, today: today))
            .help(checked ? "Done today. Click to undo" : "Done today")
            .accessibilityLabel(checked ? "Undo today: \(habit.title)" : "Done today: \(habit.title)")
        }
        .padding(.vertical, Spacing.s)
        .contentShape(.rect)
        .contextMenu {
            Button("Edit Habit…") { edit(habit) }
            Button("Stop Tracking") {
                var archived = habit
                archived.archived = true
                update(archived)
            }
        }
    }
}

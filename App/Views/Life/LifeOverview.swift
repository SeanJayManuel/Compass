import Core
import SwiftData
import SwiftUI

/// The year at a glance: this week's calendar, then Reminders read by
/// horizon (what's to do this week and admin, the quarter's goals and what's
/// coming up, and the living list under the vision), with the habits (one for
/// each daily reminder) under To do and the Playbook's today under the vision. Reminders holds the lists; Compass adds the habits, the
/// quarter clock and money progress.
struct LifeOverview: View {
    @Environment(\.modelContext) private var context
    @Environment(RemindersService.self) private var reminders
    @Query(sort: \HabitRecord.createdAt) private var habitRecords: [HabitRecord]
    @Query(sort: \PlaybookEntryRecord.createdAt) private var playbookRecords: [PlaybookEntryRecord]
    @Environment(Navigator.self) private var navigator
    /// Read by `ReminderAgenda.life`; here so a change redraws.
    @AppStorage(RemindersLists.hiddenKey) private var hiddenLists: String?
    @Environment(HabitTicker.self) private var ticker
    @State private var editingHabit: Habit?
    @State private var twoColumns = true

    private var today: Day { Day(.now, in: .current) }

    var body: some View {
        let habits = habitRecords.compactMap(\.habit).filter { !$0.archived }
        let quarter = Quarter(today)
        let agenda = ReminderAgenda.life(reminders, habits: habits, playbook: playbookRecords.compactMap(\.entry), today: today)

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text(quarter.clock(today: today))
                    .font(Typeface.body).foregroundStyle(Palette.inkSecondary)

                WeekBand(today: today)

                // As the draft: the habits beside To do
                // (with Admin), then the quarter (with Coming up), then the
                // vision they kept. One column when the window is narrow.
                // Side by side at the same height (no gap under the shorter
                // card); stacked when the window is narrow.
                let habitsCard = HabitsGlance(
                    today: today, habits: habits,
                    update: { try? CompassStore(context: context).save($0) },
                    toggle: { ticker.toggle($0, on: $1, today: today, context: context) },
                    edit: { editingHabit = $0 }, strip: true)
                if twoColumns {
                    HStack(alignment: .top, spacing: Spacing.m) {
                        habitsCard
                        ToDoGlance(today: today, agenda: agenda)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    habitsCard
                    ToDoGlance(today: today, agenda: agenda)
                }
                QuarterGlance(quarter: quarter, today: today, agenda: agenda)
                VisionGlance(today: today, agenda: agenda)
            }
            .screenColumn()
            .onGeometryChange(for: Bool.self) {
                $0.size.width >= 760 * TextSize.current.scale
            } action: {
                twoColumns = $0
            }
        }
        .background(Palette.canvas)
        .perfMark("screen.life")
        .onChange(of: navigator.newHabitRequest) { _, _ in
            editingHabit = Habit(title: "", perWeek: 3, startedOn: today)
        }
        .sheet(item: $editingHabit) { HabitEditor(habit: $0, habits: habits) }
        // Ticks made in Reminders (on their phone, say) reach their habits.
        .onChange(of: reminders.reminders, initial: true) { carryOver() }
        .onChange(of: reminders.completed) { carryOver() }
        .onChange(of: reminders.loaded) { carryOver() }
    }

    private func carryOver() { ticker.carryOver(context: context) }
}

/// Every habit with this week's days to tick. Its trends are on the Habits screen.
struct HabitsGlance: View {
    let today: Day
    let habits: [Habit]
    let update: (Habit) -> Void
    /// Ticks or unticks a day; a linked reminder may tick off with it.
    let toggle: (Habit, Day) -> Void
    let edit: (Habit) -> Void
    /// After its link picks Habits: the menu bar panel opens the window.
    var opened: () -> Void = {}
    /// The Life overview's rows, as the draft: two weeks of days and today's
    /// tick. The menu bar keeps this week's day buttons.
    var strip = false
    @Environment(Navigator.self) private var navigator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if strip {
                GlanceHeader(title: "Habits", link: "Last 2 weeks") {
                    navigator.screen = .habits; opened()
                }
                .padding(.bottom, Spacing.xs)
            } else {
                GlanceHeader(title: "Habits", link: "Habits") {
                    navigator.screen = .habits; opened()
                }
                .padding(.bottom, Spacing.xs)
            }
            if habits.isEmpty {
                RemindersNote("Each daily reminder becomes a habit here. Add one of your own, like running three times a week, with New Habit.")
            }
            ForEach(habits) { habit in
                Rule()
                if strip {
                    HabitStripRow(habit: habit, today: today, update: update, toggle: toggle, edit: edit)
                } else {
                    HabitRow(habit: habit, today: today, update: update, toggle: toggle, edit: edit)
                }
            }
        }
        // A half-width card: each habit's days take their own line.
        .environment(\.rowDensity, .compact)
        .frame(maxWidth: .infinity, maxHeight: strip ? .infinity : nil, alignment: .topLeading)
        .card(padding: strip ? Spacing.m : Spacing.l)
    }
}

extension Quarter {
    /// "Q4 2026 · day 25 of 92 · 68 days left".
    func clock(today: Day) -> String {
        let left = end.ordinal - today.ordinal + 1
        return "\(name) · day \(dayNumber(of: today)) of \(days) · \(left) \(left == 1 ? "day" : "days") left"
    }
}

/// The This Quarter list from Reminders: each goal with its deadline, and a
/// bar for one that follows net worth or a money goal. Then what's coming up
/// in the next few months that isn't a quarter goal.
private struct QuarterGlance: View {
    let quarter: Quarter
    let today: Day
    let agenda: ReminderAgenda?
    @Environment(NetWorthCache.self) private var cache
    @Environment(RemindersService.self) private var service
    @Environment(\.modelContext) private var context
    @Query private var linkRecords: [ReminderMeasureRecord]
    @State private var linking: Reminder?

    var body: some View {
        let links = linkRecords.compactMap(\.link)
        let quarterName = ReminderListNames.saved.quarter.first ?? "This Quarter"
        let hasList = service.lists.contains { ReminderListNames.saved.matches(.quarter, $0.title) }
        let listNames = Dictionary(service.lists.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: Spacing.s) {
            GlanceHeader(title: "This quarter", link: "Reminders") { service.openReminders() }
            if let agenda {
                if agenda.quarter.isEmpty {
                    let nothingLeft: String = "Nothing left on \(quarterName) for \(quarter.name)."
                    let makeOne: String =
                        "Make a list called \(quarterName) in Reminders, and its goals show here. Settings › Data can use a list you already have."
                    RemindersNote(hasList ? nothingLeft : makeOne)
                }
                ReminderSection(title: "This quarter", items: agenda.quarter, headed: false) { reminder in
                    row(reminder, link: ReminderMeasure.link(for: reminder, in: links))
                }
                // Deadlines in the next few months that aren't the quarter's goals.
                if !agenda.comingUp.isEmpty {
                    ReminderSection(title: "Coming up", items: agenda.comingUp) { reminder in
                        ReminderRow(
                            reminder: reminder, today: today,
                            title: ReminderAgenda.shortTitle(reminder.title, list: listNames[reminder.listID] ?? ""))
                    }
                    .padding(.top, Spacing.xs)
                }
            } else {
                RemindersNote("Your This Quarter list from Reminders shows here once Compass can see Reminders.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card(padding: Spacing.m)
        .sheet(item: $linking) { reminder in
            ReminderMeasureEditor(reminder: reminder, existing: ReminderMeasure.link(for: reminder, in: links))
        }
    }

    private func row(_ reminder: Reminder, link: ReminderMeasure?) -> some View {
        ReminderRow(reminder: reminder, today: today) {
            if let link, let fraction = link.fraction(values: cache.linkedValues) {
                let percent = Int(NSDecimalNumber(decimal: fraction * 100).doubleValue.rounded(.down))
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.s) {
                        MeterBar(fraction: fraction.chartValue, height: 6, label: "\(percent) percent")
                        Text("\(percent)%").font(Typeface.detail).monospacedDigit().foregroundStyle(Palette.inkSecondary)
                    }
                    if let reward = link.reward { rewardLine(reward, link: link, fraction: fraction) }
                }
                .padding(.top, Spacing.xs)
            } else if link == nil, ReminderMeasure.suggestedTarget(in: reminder.title) != nil {
                // A goal with an amount in it can follow the number it names.
                Button("Show Progress") { linking = reminder }
                    .linkButton().font(Typeface.detail)
                    .help("Follow net worth or a money goal, with a bar")
            }
        } actions: {
            Button(link == nil ? "Follow a Number…" : "Change What It Follows or Its Reward…") { linking = reminder }
            if let link {
                Button("Stop Following") { try? CompassStore(context: context).delete(link) }
            }
        }
    }

    /// Its reward, as a money goal's: unlocked at 100%, then claimed.
    private func rewardLine(_ reward: Reward, link: ReminderMeasure, fraction: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Reward: \(reward.name)").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            rewardState(reward, link: link, fraction: fraction)
        }
    }

    private func rewardState(_ reward: Reward, link: ReminderMeasure, fraction: Decimal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            if let cost = reward.cost {
                Text(cost.wholeDollars).font(Typeface.detail).monospacedDigit().foregroundStyle(Palette.inkSecondary).privateAmount()
            }
            if let claimed = reward.claimedOn {
                StatusLabel(
                    text: "Claimed \(claimed.startDate(in: .current).formatted(date: .abbreviated, time: .omitted))",
                    symbol: "checkmark", tone: .good)
            } else if fraction >= 1 {
                Button("Mark Claimed") {
                    guard let claimed = try? ClaudeRules.setReward(link, name: nil, cost: nil, claimedOn: today, progress: fraction, today: today)
                    else { return }
                    try? CompassStore(context: context).save(claimed)
                }
                .linkButton().font(Typeface.detail)
            }
        }
    }
}

/// Links a quarter reminder to net worth or a money goal, with a target.
private struct ReminderMeasureEditor: View {
    let reminder: Reminder
    let existing: ReminderMeasure?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \GoalRecord.createdAt) private var goals: [GoalRecord]
    @State private var measure: LinkedMeasure
    @State private var target: Decimal?
    @State private var rewardName: String
    @State private var rewardCost: Decimal?

    init(reminder: Reminder, existing: ReminderMeasure?) {
        self.reminder = reminder
        self.existing = existing
        _measure = State(initialValue: existing?.measure ?? .netWorth)
        _target = State(initialValue: existing?.target ?? ReminderMeasure.suggestedTarget(in: reminder.title))
        _rewardName = State(initialValue: existing?.reward?.name ?? "")
        _rewardCost = State(initialValue: existing?.reward?.cost)
    }

    /// No name, no reward; a claim already made stays.
    private var reward: Reward? {
        let name = rewardName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : Reward(name: name, cost: rewardCost, claimedOn: existing?.reward?.claimedOn)
    }

    var body: some View {
        Form {
            Text(reminder.title).font(Typeface.body).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Follows", selection: $measure) {
                Text("Net worth").tag(LinkedMeasure.netWorth)
                ForEach(goals) { record in
                    Text("Goal: \(record.goal.name)").tag(LinkedMeasure.moneyGoal(record.id))
                }
            }
            TextField(
                "Target", value: $target, format: .currency(code: "USD").precision(.fractionLength(0)),
                prompt: Text("$50,000"))
            Text("A bar under the goal fills as the number grows. The reminder stays in Reminders; tick it off when it's done.")
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Section("Reward") {
                TextField("Reward", text: $rewardName, prompt: Text("Optional, like a weekend away"))
                TextField("Cost", value: $rewardCost, format: .currency(code: "USD").precision(.fractionLength(0)), prompt: Text("$900"))
                Text("It unlocks when the bar is full. A reward is spending, never counted in net worth.")
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
                    guard let target, target > 0 else { return }
                    try? CompassStore(context: context).save(
                        ReminderMeasure(
                            id: existing?.id ?? UUID(), reminderID: reminder.id, title: reminder.title,
                            measure: measure, target: target, reward: reward))
                    dismiss()
                }
                .disabled((target ?? 0) <= 0 || (rewardCost ?? 0) < 0)
            }
        }
    }
}

/// The vision in their words, edited in place, then this year's bets and the
/// Living List from Reminders: what it's all for, what they're betting the year
/// on, and things to try on the way.
private struct VisionGlance: View {
    let today: Day
    let agenda: ReminderAgenda?
    @Environment(RemindersService.self) private var service
    @Query private var visions: [VisionRecord]
    @Query private var bets: [YearlyBetsRecord]
    @State private var editing = false

    var body: some View {
        let vision = (visions.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let listNames = Dictionary(service.lists.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Vision").font(Typeface.section).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.s)
                Button(editing ? "Done" : "Edit") { withAnimation(Motion.change) { editing.toggle() } }
                    .linkButton().font(Typeface.detail)
                    .keyboardShortcut(editing ? .cancelAction : nil)
                    .accessibilityLabel(editing ? "Done editing the vision" : "Edit the vision")
            }
            if editing {
                VisionEditor()
            } else if vision.isEmpty {
                RemindersNote("Write a few lines on what a good life looks like, and they'll sit here as a reminder.")
            } else {
                Text(vision).font(VisionEditor.font).foregroundStyle(Palette.ink)
                    // All of it: the vision is read whole, not as a teaser.
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture(count: 2) { withAnimation(Motion.change) { editing = true } }
            }
            BetsSection(year: today.year, record: bets.first { $0.year == today.year }, editing: editing)
            if let agenda, !agenda.livingList.isEmpty {
                ReminderSection(title: "Living list", items: agenda.livingList, flow: true) { reminder in
                    ReminderChip(
                        reminder: reminder,
                        title: ReminderAgenda.shortTitle(reminder.title, list: listNames[reminder.listID] ?? ""))
                }
                .padding(.top, Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card(padding: Spacing.m)
    }
}

/// This year's bets under the vision: a line each, or, while the card is
/// being edited, a field with one a line that saves as they type.
private struct BetsSection: View {
    let year: Int
    let record: YearlyBetsRecord?
    let editing: Bool
    @Environment(\.modelContext) private var context
    @State private var text = ""

    var body: some View {
        let bets = YearlyBets.lines(record?.text ?? "")
        if editing || !bets.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("\(String(year)) bets").font(Typeface.detail.weight(.semibold)).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                if editing {
                    TextField("Bets", text: $text, prompt: Text("One a line: savings, the gym, people, work"), axis: .vertical)
                        .textFieldStyle(.plain).font(Typeface.body).lineLimit(3...)
                        .onAppear { text = record?.text ?? "" }
                        .onChange(of: text) { _, new in try? CompassStore(context: context).saveBets(new, year: year) }
                        .accessibilityLabel("\(String(year)) bets, one a line")
                } else {
                    ForEach(Array(bets.enumerated()), id: \.offset) { index, bet in
                        if index > 0 { Rule() }
                        Text(bet).font(Typeface.body).foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, Spacing.xs)
                    }
                }
            }
            .padding(.top, Spacing.s)
        }
    }
}

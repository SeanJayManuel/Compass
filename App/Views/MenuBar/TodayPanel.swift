import AppKit
import Core
import SwiftData
import SwiftUI

/// Settings > Appearance: whether the panel's icon is in the menu bar. Not
/// `@AppStorage` on the App, which redraws every scene on each write.
@MainActor @Observable final class MenuBarSetting {
    static let key = "menuBar.shown"

    @ObservationIgnored private var stored = UserDefaults.standard.object(forKey: MenuBarSetting.key) as? Bool ?? true

    /// Only a change is reported: MenuBarExtra writes its binding back as it
    /// draws, and reporting those would redraw the scenes without end.
    var shown: Bool {
        get {
            access(keyPath: \.shown)
            return stored
        }
        set {
            guard newValue != stored else { return }
            withMutation(keyPath: \.shown) { stored = newValue }
            UserDefaults.standard.set(newValue, forKey: Self.key)
        }
    }
}

/// The menu bar panel: what's due today from Reminders, what's left to spend
/// this month, and the habits. Nothing shows while Compass is locked, and
/// the menu bar icon never carries a number.
struct TodayPanel: View {
    @Environment(AppLock.self) private var lock
    @Environment(SyncService.self) private var sync

    var body: some View {
        Group {
            if lock.isLocked {
                locked
            } else {
                TodayView()
                    // As tall as it needs, up to most of a 13-inch screen.
                    .frame(maxHeight: 640)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 380 * TextSize.current.scale)
        .background(Palette.canvas)
        // With the window closed, nothing else syncs: catch up when they look.
        .task(id: lock.isLocked) { if !lock.isLocked { await sync.syncIfDue() } }
    }

    private var locked: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "lock.fill").font(Typeface.title).foregroundStyle(Palette.inkSecondary)
                .accessibilityHidden(true)
            Text("Compass is locked").font(Typeface.body).foregroundStyle(Palette.ink)
            Button("Unlock") { Task { await lock.unlock() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.l)
    }

}

/// The panel's cards, unlocked.
struct TodayView: View {
    @Environment(Navigator.self) private var navigator
    @Environment(RemindersService.self) private var reminders
    @Environment(HabitTicker.self) private var ticker
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \HabitRecord.createdAt) private var habitRecords: [HabitRecord]
    @Query(sort: \PlaybookEntryRecord.createdAt) private var playbookRecords: [PlaybookEntryRecord]
    /// Read by `ReminderAgenda.life`; here so a change redraws.
    @AppStorage(RemindersLists.hiddenKey) private var hiddenLists: String?

    private var today: Day { Day(.now, in: .current) }

    var body: some View {
        let habits = habitRecords.compactMap(\.habit).filter { !$0.archived }
        let agenda = ReminderAgenda.life(reminders, habits: habits, playbook: playbookRecords.compactMap(\.entry), today: today)
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Open Compass") { openCompass() }.linkButton().font(Typeface.detail)
                }
                TodayCard(today: today, agenda: agenda) { show(.life) }
                // Short, so it stays in view above the habits.
                FlexibleGlance(today: today, opened: openCompass)
                if !habits.isEmpty {
                    HabitsGlance(
                        today: today, habits: habits,
                        update: { try? CompassStore(context: context).save($0) },
                        toggle: { ticker.toggle($0, on: $1, today: today, context: context) },
                        edit: { _ in show(.habits) }, opened: openCompass)
                }
            }
            .padding(Spacing.m)
        }
        // Ticks made in Reminders (on their phone, say) reach their habits, as on Life.
        .onChange(of: reminders.reminders, initial: true) { ticker.carryOver(context: context) }
        .onChange(of: reminders.completed) { ticker.carryOver(context: context) }
        .onChange(of: reminders.loaded) { ticker.carryOver(context: context) }
    }

    private func show(_ screen: Screen) {
        navigator.screen = screen
        openCompass()
    }

    private func openCompass() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// Reminders overdue or due today, each with its tick, and how many more are due this week.
private struct TodayCard: View {
    let today: Day
    let agenda: ReminderAgenda?
    let openLife: () -> Void
    @Environment(RemindersService.self) private var service

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            GlanceHeader(title: "Today", link: "Life", action: openLife)
            switch service.access {
            case .notAsked:
                RemindersNote("See what's due today from Reminders, and tick things off here.")
                Button("Show Reminders") { Task { await service.requestAccess() } }
            case .denied:
                RemindersNote("Compass can't see your reminders. You can turn that on in System Settings, under Privacy & Security.")
                Button("Open Privacy Settings") { service.openPrivacySettings() }
            case .granted:
                if let agenda {
                    let due = agenda.today(today)
                    let later = agenda.laterThisWeek(today)
                    if due.isEmpty { RemindersNote("Nothing due today.") }
                    ReminderSection(title: "Today", items: due, headed: false) { reminder in
                        ReminderRow(reminder: reminder, today: today, weekly: true)
                    }
                    if later > 0 {
                        Text("\(later) more this week").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card(padding: Spacing.l)
    }
}

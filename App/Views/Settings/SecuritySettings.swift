import AppKit
import Core
import SwiftData
import SwiftUI

/// When Compass locks, hiding amounts, and Claude's access.
struct SecuritySettings: View {
    @Environment(AppLock.self) private var lock
    @AppStorage(LockSettings.modeKey) private var mode = LockMode.onLaunch
    @AppStorage(LockSettings.key) private var lockAfterMinutes = 15
    @AppStorage(HideAmounts.key) private var hideAmounts = false
    @Environment(ClaudeEndpoint.self) private var claude
    @AppStorage(ClaudeAccess.enabledKey) private var claudeEnabled = false
    @State private var copied: String?
    @Query(sort: \ClaudeActivityRecord.at, order: .reverse) private var records: [ClaudeActivityRecord]

    private var changes: [ClaudeActivity] { records.compactMap(\.activity) }

    var body: some View {
        Form {
            Section {
                Picker("Lock Compass", selection: $mode) {
                    Text("Off").tag(LockMode.off)
                    Text("When it opens").tag(LockMode.onLaunch)
                    Text("After sleep or idle").tag(LockMode.afterSleepOrIdle)
                }
                if mode == .afterSleepOrIdle {
                    Picker("Lock after", selection: $lockAfterMinutes) {
                        ForEach(LockSettings.choices, id: \.self) { minutes in
                            Text(minutes == 0 ? "Never" : minutes == 1 ? "1 minute idle" : "\(minutes) minutes idle").tag(minutes)
                        }
                    }
                }
                SettingsNote(modeNote)
                Toggle("Hide amounts (⌘⇧H)", isOn: $hideAmounts)
                if !FileVault.isOn {
                    Label(
                        "FileVault is off, so Compass's data isn't encrypted on disk. Turn it on in System Settings > Privacy & Security.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(Typeface.detail)
                    .foregroundStyle(Palette.behind)
                }
            } header: {
                SettingsHeader("Security")
            }

            Section {
                Toggle("Allow Claude access", isOn: $claudeEnabled)
                if claudeEnabled {
                    HStack(spacing: Spacing.s) {
                        Button("Copy Claude Code Command") { copy(ClaudeAccess.claudeCodeCommand, as: "Claude Code command") }
                        Button("Copy Claude Desktop Setup") { copy(ClaudeAccess.claudeDesktopEntry, as: "Claude desktop setup") }
                    }
                    if !keyReadable {
                        SettingsNote(
                            "Compass can't read its Claude key from the Keychain, so Claude can't connect. Quit and reopen Compass and allow Keychain access if asked; New Key replaces the key if that doesn't help.",
                            color: Palette.failure)
                    }
                    Button("New Key") {
                        ClaudeAccess.newKey()
                        copied = "New key made. Copy the setup again into Claude; the old one no longer works."
                    }
                    if let failure = claude.failure {
                        SettingsNote(failure, color: Palette.failure)
                    } else if let copied {
                        SettingsNote(copied, color: Palette.onPace)
                    }
                }
                SettingsNote(
                    "Lets Claude on this Mac read what Compass shows (net worth, accounts by name, goals, investing contributions, budget, spending, transactions, Reminders, habits, your vision and Calendar) whenever it's running; it opens in the background when Claude needs it. Never account numbers or bank details. Only this Mac can connect, with the key in the setup."
                )
                SettingsNote(
                    "Claude can also set up and change money goals (never delete them or touch balances), add, edit or tick off reminders, add habits and check-ins, edit your vision, and add events to a Compass calendar, moving or deleting only its own. Each change is listed below, with Undo. Accounts, balances, transactions, categories, budgets and sync stay read-only."
                )
            } header: {
                SettingsHeader("Claude")
            }

            if claudeEnabled || !changes.isEmpty {
                ClaudeChanges(changes: changes)
            }
        }
        .settingsPane()
        .onChange(of: mode) { _, mode in lock.setMode(mode) }
        .onChange(of: claudeEnabled) { _, enabled in
            copied = nil
            claude.setEnabled(enabled)
        }
        .onChange(of: lockAfterMinutes) { _, _ in lock.setIdleTimeout(LockSettings.idleTimeout) }
    }

    private var keyReadable: Bool { ClaudeAccess.key != nil }

    private func copy(_ text: String?, as name: String) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = "Copied the \(name). It holds the key, so paste it only into Claude."
    }

    private var modeNote: String {
        switch mode {
        case .off: "Compass never asks for Touch ID. Your Mac's login protects it, so lock the Mac when you step away."
        case .onLaunch: "Touch ID once when Compass opens; it stays unlocked until you quit. Lock Now (⌘L) locks it sooner."
        case .afterSleepOrIdle: "Compass also locks on launch, when the Mac sleeps or its screen locks, and on Lock Now (⌘L)."
        }
    }
}

/// The changes Claude made, newest first, each with Undo: the last few here,
/// the rest in a sheet.
private struct ClaudeChanges: View {
    let changes: [ClaudeActivity]
    @Environment(ClaudeEndpoint.self) private var claude
    @State private var problem: String?
    @State private var showingAll = false

    private static let shown = 5

    var body: some View {
        Section {
            if changes.isEmpty {
                SettingsNote("Nothing yet. Each change Claude makes shows here, with Undo.")
            } else {
                ForEach(changes.prefix(Self.shown)) { ClaudeChangeRow(change: $0, undo: undo) }
                if changes.count > Self.shown {
                    Button("Show All \(changes.count) Changes") { showingAll = true }
                }
            }
            if let problem { SettingsNote(problem, color: Palette.failure) }
        } header: {
            SettingsHeader("Changes by Claude")
        }
        .sheet(isPresented: $showingAll) {
            AllClaudeChanges(changes: changes, undo: undo)
                .environment(\.settingsInCanvas, false)
        }
    }

    private func undo(_ change: ClaudeActivity) {
        do {
            try claude.tools.undo(change.id)
            problem = nil
        } catch let failure as Problem {
            problem = "Couldn't undo “\(change.summary)”. \(failure.message)"
        } catch let refusal as ClaudeRefusal {
            problem = "Couldn't undo “\(change.summary)”. \(refusal.message)"
        } catch {
            problem = "Couldn't undo “\(change.summary)”. \(error.localizedDescription)"
        }
    }
}

private struct AllClaudeChanges: View {
    let changes: [ClaudeActivity]
    let undo: (ClaudeActivity) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                ForEach(changes) { ClaudeChangeRow(change: $0, undo: undo) }
            } header: {
                SettingsHeader("Changes by Claude")
            }
        }
        .settingsPane()
        .frame(height: 520 * TextSize.current.scale)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}

/// What Claude did, when, and Undo (or that it was undone).
private struct ClaudeChangeRow: View {
    let change: ClaudeActivity
    let undo: (ClaudeActivity) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                summary
                    .foregroundStyle(change.undoneAt == nil ? Palette.ink : Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.when(change.at))
                    .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: Spacing.s)
            if change.undoneAt == nil {
                Button("Undo") { undo(change) }
                    .accessibilityLabel("Undo: \(change.summary)")
            } else {
                Text("Undone").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    /// Goal changes carry dollar amounts, so Hide Amounts hides them.
    @ViewBuilder private var summary: some View {
        switch change.change {
        case .goalCreated, .goalChanged: Text(change.summary).privateAmount()
        default: Text(change.summary)
        }
    }

    /// "Today at 9:41 AM", "Yesterday at 6:02 PM", or "Oct 21 at 8:15 AM".
    private static func when(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today at \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }
}

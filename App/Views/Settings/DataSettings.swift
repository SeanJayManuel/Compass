import AppKit
import Core
import SwiftData
import SwiftUI

/// The SimpleFIN connection, the Reminders lists and calendars the Life overview shows, and backups.
struct DataSettings: View {
    @Environment(SyncService.self) private var sync
    @Environment(RemindersService.self) private var reminders
    @AppStorage(RemindersLists.hiddenKey) private var hiddenLists: String?
    @Environment(CalendarService.self) private var calendar
    @AppStorage(CalendarLists.hiddenKey) private var hiddenCalendars = ""
    @Environment(\.modelContext) private var context
    @AppStorage("backup.lastExport") private var lastExport: Double = 0
    @State private var backingUp = false
    @State private var backupMessage: String?
    @State private var backupFailed = false
    @AppStorage(MerchantLogos.enabledKey) private var fetchLogos = true
    @State private var logoKey = ""
    @State private var logoKeyMessage: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: sync.isConnected ? "Connected" : "Not connected")
                if sync.isConnected {
                    Button("Disconnect SimpleFIN", role: .destructive) { sync.disconnect() }
                    SettingsNote("Disconnecting forgets the saved access. Synced accounts and their history stay.")
                } else {
                    SettingsNote("To connect, use Connect SimpleFIN in the toolbar of any money screen.")
                }
            } header: {
                SettingsHeader("SimpleFIN")
            }

            Section {
                Toggle("Show merchant logos", isOn: $fetchLogos)
                LabeledContent("logo.dev key") {
                    HStack {
                        SecureField(
                            "logo.dev key", text: $logoKey,
                            prompt: Text(MerchantLogos.shared.hasKey ? "Saved" : "pk_…")
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        Button(logoKey.isEmpty && MerchantLogos.shared.hasKey ? "Remove" : "Save") {
                            do {
                                try MerchantLogos.shared.setKey(logoKey)
                                logoKeyMessage = logoKey.isEmpty ? "Removed. Logos come from Google again." : "Saved. Sharper logos load as you browse."
                                logoKey = ""
                            } catch { logoKeyMessage = error.localizedDescription }
                        }
                        .disabled(logoKey.isEmpty && !MerchantLogos.shared.hasKey)
                    }
                }
                if let logoKeyMessage { SettingsNote(logoKeyMessage) }
                Button("Forget Saved Logos") { MerchantLogos.shared.forget() }
                SettingsNote(
                    "Compass asks for a known merchant's logo once, by its website's name alone (doordash.com), and keeps it on this Mac: from logo.dev when you've saved a free key from logo.dev (sharper), otherwise from Google's icon service. People, transfers and pay are never looked up; a payment or trade at your bank or broker shows that bank's logo. Off shows initials and asks for nothing."
                )
            } header: {
                SettingsHeader("Merchant logos")
            }

            Section {
                if reminders.access == .granted {
                    let hidden = RemindersLists.hidden(hiddenLists, lists: reminders.lists)
                    ForEach(reminders.lists) { list in
                        Toggle(
                            list.title,
                            isOn: Binding(
                                get: { !hidden.contains(list.id) },
                                set: { shown in
                                    hiddenLists = RemindersLists.store(shown ? hidden.subtracting([list.id]) : hidden.union([list.id]))
                                }))
                    }
                    SettingsNote("The lists the Life overview shows.")
                } else {
                    SettingsNote("To show your reminders, use Show Reminders on the Life overview.")
                }
            } header: {
                SettingsHeader("Reminders")
            }

            Section {
                ForEach(ReminderListNames.Role.allCases, id: \.self) { role in
                    ReminderListNameField(role: role)
                }
                SettingsNote(
                    "Compass gives these lists a job by name. Use your own list names here (several, separated by commas), or leave a field empty for the name shown in grey."
                )
            } header: {
                SettingsHeader("Reminders list names")
            }

            Section {
                switch calendar.access {
                case .granted:
                    let hidden = CalendarLists.hidden(hiddenCalendars)
                    ForEach(calendar.calendars) { source in
                        Toggle(
                            source.title,
                            isOn: Binding(
                                get: { !hidden.contains(source.id) },
                                set: { shown in
                                    hiddenCalendars = CalendarLists.store(shown ? hidden.subtracting([source.id]) : hidden.union([source.id]))
                                }))
                    }
                    SettingsNote("The calendars whose events show in This week on the Life overview.")
                case .notAsked:
                    SettingsNote("To show your events, use Show Calendar on the Life overview.")
                case .denied:
                    SettingsNote("Compass can't see your calendars. You can turn that on in System Settings, under Privacy & Security.")
                    Button("Open Privacy Settings") { calendar.openPrivacySettings() }
                }
            } header: {
                SettingsHeader("Calendar")
            }

            Section {
                LabeledContent("Last backup") {
                    Text(lastExport == 0 ? "Never" : Date(timeIntervalSince1970: lastExport).formatted(date: .abbreviated, time: .shortened))
                }
                HStack(spacing: Spacing.s) {
                    Button("Back Up Now", action: backUp).disabled(backingUp)
                    if backingUp {
                        ProgressView().controlSize(.small)
                        Text("Saving…").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                    }
                }
                SettingsNote(
                    "Saves a folder with everything in Compass as one file to restore from, plus balances and transactions as spreadsheets. It includes your balances, so keep it somewhere private."
                )
                if let backupMessage {
                    SettingsNote(backupMessage, color: backupFailed ? Palette.failure : Palette.onPace)
                }
            } header: {
                SettingsHeader("Backup")
            }

            if DataEnvironment.current == .sandbox {
                Section {
                    SettingsNote("Sandbox data", color: Palette.behind)
                }
            }
        }
        .settingsPane()
    }

    /// Reads, encodes and writes off the main thread, in a context of its
    /// own, so the window keeps drawing (and the spinner keeps turning) while
    /// tens of thousands of rows are fetched.
    private func backUp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Back Up Here"
        panel.message = "Choose where to save the backup folder."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        backingUp = true
        backupMessage = nil
        let container = context.container
        Task {
            do {
                // The background context reads only what's saved.
                if context.hasChanges { try context.save() }
                let saved = try await Task.detached(priority: .userInitiated) {
                    let bundle = try CompassStore.backupBundle(in: ModelContext(container), at: .now)
                    return try BackupWriter.write(bundle, into: folder)
                }.value
                lastExport = Date.now.timeIntervalSince1970
                backupFailed = false
                backupMessage = "Saved \(saved.lastPathComponent)."
            } catch {
                backupFailed = true
                backupMessage = "The backup couldn't be saved: \(error.localizedDescription)"
            }
            backingUp = false
        }
    }
}

/// One Reminders list Compass gives a job to, by the name typed here.
private struct ReminderListNameField: View {
    let role: ReminderListNames.Role
    @AppStorage private var names: String

    init(role: ReminderListNames.Role) {
        self.role = role
        _names = AppStorage(wrappedValue: "", role.key)
    }

    var body: some View {
        TextField(role.label, text: $names, prompt: Text(ReminderListNames.standard[role].joined(separator: ", ")))
            .help(role.purpose)
    }
}

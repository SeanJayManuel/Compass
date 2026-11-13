import Core
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The top bar's actions and the sheets they open. Money screens get add
/// account, import and sync; every screen gets the ⓘ, which opens how the
/// screen works in Settings. Built once in the top bar, so moving between
/// screens keeps them rather than rebuilding them.
struct TopBarActions: View {
    let screen: Screen
    @Environment(\.modelContext) private var context
    @Environment(Navigator.self) private var navigator
    @Environment(SyncService.self) private var sync
    @Environment(\.railForcedFolded) private var narrow
    @AppStorage(SettingsTab.key) private var settingsTab = SettingsTab.profile
    @AppStorage(GuideTopic.key) private var guideTopic = GuideTopic.life
    @AppStorage(SpendingChartView.key) private var spendingView = SpendingChartView.budget
    @AppStorage("netWorth.range") private var range = TimeRange.oneYear
    @State private var isAddingAccount = false
    @State private var isConnecting = false
    @State private var isImporting = false
    @State private var importResult: String?

    var body: some View {
        @Bindable var navigator = navigator
        HStack(spacing: 2 * TextSize.current.scale) {
            if DataEnvironment.current == .sandbox {
                Text("Sandbox").font(Typeface.detail).foregroundStyle(Palette.behind)
                    .padding(.trailing, Spacing.s)
            }
            if screen == .money {
                // A strip when there's room; a menu in a narrow window.
                if narrow {
                    Picker("Net worth range", selection: $range) {
                        ForEach(TimeRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().fixedSize().help("Net worth chart range")
                } else {
                    RangeSegments(range: $range)
                        .padding(.trailing, Spacing.xs)
                }
            }
            if screen == .spending {
                MonthStepper(
                    month: $navigator.spendingMonth,
                    latest: Month(Day(.now, in: .current)).adding(spendingView == .budget ? 12 : 0), compact: true
                )
                .font(Typeface.detail)
                Picker("Spending view", selection: $spendingView) {
                    ForEach(SpendingChartView.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize().help("Budget or spending over time")
                // Editing the budget and categories live in the ⋯ menu, so the
                // row isn't cluttered.
            }
            if screen == .goals {
                Button("New goal") { navigator.newGoalRequest += 1 }
                    .font(Typeface.detail).buttonStyle(.borderless)
                    .padding(.horizontal, Spacing.xs)
            }
            if screen == .review {
                if navigator.reviewSelectedCount > 0 {
                    Button("Confirm \(navigator.reviewSelectedCount)") { navigator.reviewConfirmRequest += 1 }
                        .font(Typeface.detail).buttonStyle(.borderless)
                        .accessibilityLabel("Confirm \(navigator.reviewSelectedCount) selected transactions")
                }
                Button(navigator.reviewConfirmableCount == 1 ? "Confirm 1" : "Confirm all \(navigator.reviewConfirmableCount)") {
                    navigator.reviewConfirmAllRequest += 1
                }
                .font(Typeface.detail).buttonStyle(.borderedProminent)
                .disabled(navigator.reviewConfirmableCount == 0)
            }
            if screen == .life {
                Button("New habit") { navigator.newHabitRequest += 1 }
                    .font(Typeface.detail).buttonStyle(.borderless)
            }
            if screen == .playbook {
                Button("Add") { navigator.newPlaybookRequest += 1 }
                    .font(Typeface.detail).buttonStyle(.borderless)
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityLabel("Add to Playbook")
            }
            if screen == .notes {
                Button("Add") { navigator.newNoteRequest += 1 }
                    .font(Typeface.detail).buttonStyle(.borderless)
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityLabel("Add note")
            }
            // A sync in progress shows here; its button is in the menu.
            if sync.isSyncing {
                ProgressView().controlSize(.small).padding(.horizontal, Spacing.xs)
                    .help("Syncing…").accessibilityLabel("Syncing")
            }
            // One ⋯ menu for what isn't needed every visit (an export
            // button needn't always be there):
            // accounts, import and sync on money screens, and how the screen works.
            Menu {
                if screen == .spending {
                    Button("Edit Budget…") { navigator.spendingAction = .editBudget }
                    Button("Fill In Budget from My History…") { navigator.spendingAction = .fromHistory }
                    Button("Categories…") { navigator.spendingAction = .categories }
                    Divider()
                }
                if screen.isMoney {
                    Button("Add Account…") { isAddingAccount = true }
                    Button("Import Monarch History…") { isImporting = true }
                    if sync.isConnected {
                        Button(sync.isSyncing ? "Syncing…" : "Sync Now") { Task { await sync.sync() } }
                            .disabled(sync.isSyncing)
                    } else {
                        Button("Connect SimpleFIN…") { isConnecting = true }.disabled(sync.isSyncing)
                    }
                    Divider()
                }
                Button("How This Screen Works") {
                    guideTopic = GuideTopic(screen)
                    settingsTab = .guide
                    navigator.screen = .settings
                }
            } label: {
                Image(systemName: "ellipsis").font(Typeface.body)
                    .frame(width: 30 * TextSize.current.scale, height: 30 * TextSize.current.scale)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            // Clear of the screen's own buttons (Add, New habit) beside it.
            .padding(.leading, Spacing.s)
            .help("More").accessibilityLabel("More actions")
        }
        .sheet(isPresented: $isAddingAccount) { AddAccountSheet() }
        .sheet(isPresented: $isConnecting) { ConnectSheet() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText], allowsMultipleSelection: true) { result in
            importResult = importFiles(result)
        }
        .alert("Monarch import", isPresented: Binding(get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
            Button("OK") { importResult = nil }
        } message: {
            Text(importResult ?? "")
        }
    }

    /// Reads every chosen file first, so one bad file imports nothing.
    /// Balance history and transactions can be chosen together.
    private func importFiles(_ result: Result<[URL], Error>) -> String {
        do {
            var balances: [ImportedBalance] = []
            var transactions: [ImportedTransaction] = []
            for url in try result.get() {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let text = try String(contentsOf: url, encoding: .utf8)
                do {
                    if MonarchTransactionImport.isTransactionExport(text) {
                        transactions += try MonarchTransactionImport.parse(text)
                    } else {
                        balances += try MonarchBalanceImport.parse(text, fileName: url.lastPathComponent)
                    }
                } catch {
                    return "\(url.lastPathComponent): \(error.localizedDescription) Nothing was imported."
                }
            }
            let store = CompassStore(context: context)
            var lines: [String] = []
            var newAccounts = 0
            var transfers = 0
            if !balances.isEmpty {
                let plan = MonarchBalanceImport.plan(balances, existing: try store.accounts())
                try store.apply(plan)
                newAccounts += plan.newAccounts.count
                lines.append("\(plan.snapshots.count) balances across \(Set(plan.snapshots.map(\.accountID)).count) accounts")
            }
            if !transactions.isEmpty {
                let plan = MonarchTransactionImport.plan(
                    transactions, existing: try store.accounts(),
                    knownExternalIDs: try store.knownExternalIDs())
                try store.apply(plan)
                newAccounts += plan.newAccounts.count
                lines.append("\(plan.transactions.count) new transactions (\(transactions.count - plan.transactions.count) already here)")
                // Uncategorized moves between their own accounts aren't spending.
                // Runs after apply's dedupe, from the oldest imported day on.
                if let oldest = plan.transactions.map(\.day).min() {
                    transfers = try store.fileTransfers(since: oldest)
                }
            }
            var message = "Imported " + lines.joined(separator: " and ") + "."
            if transfers > 0 {
                message +=
                    transfers == 1
                    ? " 1 transaction moving money between your accounts was filed under Transfer."
                    : " \(transfers) transactions moving money between your accounts were filed under Transfer."
            }
            if newAccounts > 0 { message += " \(newAccounts) new accounts were added; check each one's type in Accounts." }
            return message
        } catch {
            return "Nothing was imported. \(error.localizedDescription)"
        }
    }
}

/// The net worth range as one strip of segments, as the draft draws it:
/// the chosen one on a quiet tint.
private struct RangeSegments: View {
    @Binding var range: TimeRange

    var body: some View {
        let scale = TextSize.current.scale
        HStack(spacing: 2) {
            ForEach(TimeRange.allCases, id: \.self) { option in
                let on = option == range
                Button {
                    range = option
                } label: {
                    Text(option.rawValue)
                        .font(Typeface.detail.weight(on ? .medium : .regular))
                        .monospacedDigit()
                        .foregroundStyle(on ? Palette.ink : Palette.inkSecondary)
                        .padding(.horizontal, 8 * scale)
                        .frame(height: 24 * scale)
                        .background(on ? Palette.selectedFill : .clear, in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.control))
        .overlay(Hairline(cornerRadius: Radius.control))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Net worth range")
    }
}

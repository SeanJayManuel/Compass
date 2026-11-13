import Core
import SwiftData
import SwiftUI

/// One Accounts card with expandable class rows and archived accounts last,
/// with the sheets for editing an account.
struct AccountsBreakdown: View {
    @Environment(\.modelContext) private var context
    @Environment(NetWorthCache.self) private var cache
    @Query(sort: \AccountRecord.createdAt) private var accountRecords: [AccountRecord]
    let today: Day
    @State private var editing: Account?
    @State private var merging: Account?
    @State private var loggingBalanceFor: Account?
    @State private var error: String?
    /// Accounts whose own history is open. Not remembered, so opening the
    /// screen never starts a fetch.
    @State private var expandedAccounts: Set<UUID> = []

    var body: some View {
        let accounts = accountRecords.map(\.account)
        let latest = cache.latest
        let active = accounts.filter { account in account.archivedOn.map { $0 > today } ?? true }
        let archived = accounts.filter { account in account.archivedOn.map { $0 <= today } ?? false }

        let stale = Self.staleSummary(active, latest: latest, today: today)
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Accounts").font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.s)
                Text("By class · change this month").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            // Only when something needs an update; "all up to date" says nothing.
            if !active.isEmpty, !stale.hasSuffix("all up to date.") {
                Text(stale).font(Typeface.detail).foregroundStyle(Palette.attention)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(Typeface.body).foregroundStyle(Palette.failure)
            }
            if accounts.isEmpty {
                Text("Add an account by hand, connect SimpleFIN, or import your Monarch history.")
                    .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
            }
            VStack(spacing: 0) {
                ForEach(AccountClass.allCases, id: \.self) { accountClass in
                    let group = active.filter { $0.accountClass == accountClass }
                    if !group.isEmpty {
                        ClassSection(
                            title: accountClass.label, color: Palette.accountClass(accountClass),
                            accountClass: accountClass,
                            accounts: group, archived: archived, latest: latest, today: today,
                            expandedAccounts: $expandedAccounts, menu: menu)
                    }
                }
            }
            if !archived.isEmpty {
                // Muted with secondary ink rather than opacity, so an open
                // history inside keeps its contrast.
                ClassSection(
                    title: "Archived", color: Palette.rule, accountClass: nil,
                    accounts: archived, archived: [], latest: latest, today: today,
                    muted: true, expandedAccounts: $expandedAccounts, menu: menu)
            }
        }
        .card(padding: Spacing.m)
        .sheet(item: $editing) { AccountEditor(account: $0) }
        .sheet(item: $merging) { MergeSheet(source: $0, accounts: accountRecords.map(\.account)) }
        .sheet(item: $loggingBalanceFor) { LogBalanceSheet(account: $0) }
    }

    /// "9 accounts, all up to date" or "9 accounts, 2 need an update".
    static func staleSummary(_ accounts: [Account], latest: [UUID: LatestBalance], today: Day) -> String {
        let stale = accounts.filter { account in
            if case .current = Staleness.freshness(source: account.source, lastUpdated: latest[account.id]?.day, today: today) { return false }
            return true
        }.count
        let count = accounts.count == 1 ? "1 account" : "\(accounts.count) accounts"
        return stale == 0 ? "\(count), all up to date." : "\(count), \(stale) \(stale == 1 ? "needs" : "need") an update."
    }

    @ViewBuilder
    private func menu(for account: Account, latest: LatestBalance?) -> some View {
        Button(account.source == .simplefin ? "Pin Balance…" : "Log Balance…") { loggingBalanceFor = account }
        if account.source == .simplefin, let latest, latest.source == .manual {
            Button("Remove Pin") {
                do {
                    try CompassStore(context: context).removePin(
                        BalanceSnapshot(accountID: account.id, day: latest.day, source: .manual, balance: latest.balance)
                    )
                } catch { self.error = error.localizedDescription }
            }
        }
        Button("Edit Account…") { editing = account }
        Button("Merge Into…") { merging = account }
    }
}

private struct ClassSection<Menu: View>: View {
    let title: String
    let color: Color
    /// The class this card holds, for its history line; nil for archived.
    let accountClass: AccountClass?
    @Environment(NetWorthCache.self) private var cache
    let accounts: [Account]
    /// Every archived account, for the class line's note.
    let archived: [Account]
    let latest: [UUID: LatestBalance]
    let today: Day
    /// The Archived card: secondary ink, no status colors.
    var muted = false
    @Binding var expandedAccounts: Set<UUID>
    let menu: (Account, LatestBalance?) -> Menu
    /// Remembered per class, so a class kept open stays open. Opening
    /// it shows its history and its accounts at once: one disclosure is enough.
    @Remembered private var showsAccounts: Bool
    @Environment(\.rowDensity) private var density

    init(
        title: String, color: Color, accountClass: AccountClass?, accounts: [Account],
        archived: [Account], latest: [UUID: LatestBalance], today: Day, muted: Bool = false,
        expandedAccounts: Binding<Set<UUID>>, menu: @escaping (Account, LatestBalance?) -> Menu
    ) {
        self.title = title
        self.color = color
        self.accountClass = accountClass
        self.accounts = accounts
        self.archived = archived
        self.latest = latest
        self.today = today
        self.muted = muted
        _expandedAccounts = expandedAccounts
        self.menu = menu
        _showsAccounts = Remembered(wrappedValue: false, "accounts.expanded.\(accountClass?.rawValue ?? "archived")")
    }

    var body: some View {
        let total = accounts.filter { !$0.excludedFromNetWorth }.compactMap { latest[$0.id]?.balance }.reduce(0, +)
        let ink = muted ? Palette.inkSecondary : Palette.ink
        let share = cache.breakdown.last.flatMap { point in
            NetWorthSeries.allocation(point).first { $0.accountClass == accountClass }?.share
        }
        VStack(alignment: .leading, spacing: 0) {
            Rule()
            Button {
                withAnimation(Motion.change) { showsAccounts.toggle() }
            } label: {
                // One line, as the draft: swatch, name and count, share bar,
                // share, this month's change, balance. The names are in the
                // tooltip and under the row when it's open.
                let scale = TextSize.current.scale
                HStack(spacing: Spacing.m) {
                    RoundedRectangle(cornerRadius: 2).fill(color)
                        .frame(width: 9 * scale, height: 9 * scale).accessibilityHidden(true)
                    (Text(title).foregroundStyle(ink) + Text(" · \(accounts.count)").foregroundStyle(Palette.inkSecondary))
                        .font(Typeface.body).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let share, density == .regular {
                        MeterBar(
                            fraction: share.chartValue, tint: color, height: 5,
                            label: "\(share.formatted(.percent.precision(.fractionLength(0)))) of assets"
                        )
                        .frame(width: 120 * scale)
                        Text(share.formatted(.percent.precision(.fractionLength(0))))
                            .font(Typeface.detail).monospacedDigit().foregroundStyle(Palette.inkSecondary)
                            .frame(width: 40 * scale, alignment: .trailing)
                    } else if density == .regular {
                        Color.clear.frame(width: 120 * scale + 40 * scale + Spacing.m, height: 1)
                    }
                    Group {
                        if let accountClass,
                            let change = NetWorthSeries.change(
                                in: NetWorthSeries.classSeries(cache.breakdown, for: accountClass),
                                since: today.addingMonths(-1))
                        {
                            Text(change.signedWholeDollars)
                                .foregroundStyle(
                                    BalanceHistoryMeasure(accountClass).isGood(change: change)
                                        ? Palette.onPace : Palette.inkSecondary
                                )
                                .help(
                                    "Change since \(today.addingMonths(-1).startDate(in: .current).formatted(date: .abbreviated, time: .omitted)), excluding opening balances"
                                )
                        } else {
                            Text("")
                        }
                    }
                    .font(Typeface.detail).monospacedDigit().privateAmount()
                    .frame(width: 80 * scale, alignment: .trailing)
                    Text(shown(total).wholeDollars)
                        .font(Typeface.body.weight(.medium)).monospacedDigit()
                        .foregroundStyle(ink).privateAmount()
                        .frame(width: 100 * scale, alignment: .trailing)
                    Image(systemName: "chevron.right").font(AccountsSmallType.icon)
                        .foregroundStyle(Palette.inkSecondary)
                        .rotationEffect(.degrees(showsAccounts ? 90 : 0)).accessibilityHidden(true)
                }
                .padding(.vertical, Spacing.s)
                .contentShape(.rect)
                .help(accounts.map(\.name).joined(separator: ", "))
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsAccounts ? "History and accounts shown" : "History and accounts hidden")
            .accessibilityHint("Shows or hides \(title)'s history and accounts")
            if showsAccounts {
                if let accountClass {
                    // Built only while its class is open.
                    ClassHistoryView(accountClass: accountClass, accounts: accounts, archived: archived)
                        .padding(.bottom, Spacing.m)
                        .transition(.opacity)
                }
                ForEach(accounts) { account in
                    let expanded = expandedAccounts.contains(account.id)
                    Rule()
                    Button {
                        withAnimation(Motion.change) {
                            if expanded { expandedAccounts.remove(account.id) } else { expandedAccounts.insert(account.id) }
                        }
                    } label: {
                        AccountRow(account: account, latest: latest[account.id], today: today, expanded: expanded, muted: muted)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(account, latest[account.id]) }
                    .accessibilityValue(expanded ? "History shown" : "History hidden")
                    .accessibilityHint(expanded ? "Hides its balance history" : "Shows its balance history")
                    if expanded {
                        AccountHistoryView(account: account)
                            .padding(.bottom, Spacing.m)
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    private func shown(_ total: Decimal) -> Decimal {
        accountClass.map { BalanceHistoryMeasure($0).drawn(total) } ?? total
    }

}

private struct AccountRow: View {
    let account: Account
    let latest: LatestBalance?
    let today: Day
    var expanded = false
    /// In the Archived card: secondary ink, and staleness isn't news.
    var muted = false

    var body: some View {
        let freshness = Staleness.freshness(source: account.source, lastUpdated: latest?.day, today: today)
        let pinned = account.source == .simplefin && latest?.source == .manual

        HStack(alignment: .center, spacing: Spacing.s) {
            // The class's color, the same as its swatch on "Where it sits".
            RowMark(
                text: account.institution ?? account.name,
                tint: muted ? nil : Palette.accountClass(account.accountClass))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(account.name).font(Typeface.body).foregroundStyle(muted ? Palette.inkSecondary : Palette.ink)
                    if pinned {
                        Image(systemName: "pin.fill").font(AccountsSmallType.text).foregroundStyle(Palette.inkSecondary)
                            .help("Pinned by hand. The next sync with a newer balance takes over.")
                    }
                }
                Text(detail(freshness: freshness)).font(Typeface.detail)
                    .foregroundStyle(muted ? Palette.inkSecondary : freshnessColor(freshness))
            }
            Spacer()
            // A debt reads as what's owed, as on a statement; an overpaid card
            // goes below zero.
            Text(latest.map { BalanceHistoryMeasure(account.accountClass).drawn($0.balance).dollars } ?? "No balance")
                .font(Typeface.body).monospacedDigit()
                .foregroundStyle(account.excludedFromNetWorth || muted ? Palette.inkSecondary : Palette.ink)
                .strikethrough(account.excludedFromNetWorth)
                .privateAmount()
            // Says the row opens: its history shows beneath it.
            Image(systemName: "chevron.right")
                .font(AccountsSmallType.icon)
                .foregroundStyle(Palette.inkSecondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .accessibilityHidden(true)
                // On the chevron, not the row, so the pin keeps its own tooltip.
                .help(expanded ? "Hide this account's history" : "Show this account's balance over time")
        }
        .padding(.vertical, Spacing.s + 2)
        .contentShape(Rectangle())
    }

    private func detail(freshness: Freshness) -> String {
        var parts: [String] = []
        switch account.source {
        case .simplefin: parts.append("Synced from \(account.institution ?? "SimpleFIN")")
        case .manual, .imported: parts.append("Entered by hand")
        }
        if let latest {
            parts.append("updated \(latest.day.startDate(in: .current).formatted(.dateTime.month(.abbreviated).day()))")
        }
        var text = parts.joined(separator: ", ")
        if case .stale(let days) = freshness { text += ". \(days) days old" }
        if account.excludedFromNetWorth { text += ". Not counted in net worth" }
        return text
    }

    private func freshnessColor(_ freshness: Freshness) -> Color {
        switch freshness {
        case .current: Palette.inkSecondary
        case .stale, .noBalance: Palette.behind
        }
    }
}

struct AccountEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(NetWorthCache.self) private var cache
    @Environment(\.dismiss) private var dismiss
    @State var account: Account
    @State private var error: String?

    private var archivedNote: String {
        guard let day = account.archivedOn, day < Day(.now, in: .current) else {
            return "An archived account keeps its history but stops counting from today."
        }
        let date = day.startDate(in: .current).formatted(date: .abbreviated, time: .omitted)
        return "An archived account keeps its history. It stops counting from \(date), the day after its last balance."
    }

    var body: some View {
        Form {
            TextField("Name", text: $account.name)
            Picker("Type", selection: $account.accountClass) {
                ForEach(AccountClass.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle(
                "Count in net worth",
                isOn: Binding(
                    get: { !account.excludedFromNetWorth },
                    set: { account.excludedFromNetWorth = !$0 }
                ))
            Toggle(
                "Archived",
                isOn: Binding(
                    get: { account.archivedOn != nil },
                    set: {
                        account.archivedOn =
                            $0
                            ? NetWorthSeries.archiveDay(lastBalance: cache.latest[account.id]?.day, today: Day(.now, in: .current))
                            : nil
                    }
                ))
            if account.archivedOn != nil {
                Text(archivedNote)
                    .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            if let error { Text(error).foregroundStyle(Palette.failure) }
        }
        .accountSheetForm(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        try CompassStore(context: context).update(account)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .disabled(account.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

private extension View {
    /// An account sheet's form, in the app's type and as wide as the Settings
    /// text size needs, as the Settings panes are.
    func accountSheetForm(width: CGFloat) -> some View {
        let scale = TextSize.current.scale
        return formStyle(.grouped)
            .font(Typeface.body)
            .controlSize(scale > 1.05 ? .large : .regular)
            .frame(width: width * scale)
    }
}

/// For one account Monarch and SimpleFIN name differently: folds its history
/// and transactions into the other and removes it.
private struct MergeSheet: View {
    let source: Account
    let accounts: [Account]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var targetID: UUID?
    @State private var error: String?

    var body: some View {
        Form {
            Text(
                "Move \(source.name)'s balance history and transactions into another account, then remove \(source.name). Use this when Monarch and SimpleFIN call the same account different names."
            )
            .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            Picker("Merge into", selection: $targetID) {
                Text("Choose an account").tag(UUID?.none)
                ForEach(accounts.filter { $0.id != source.id }) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            if let error { Text(error).foregroundStyle(Palette.failure) }
        }
        .accountSheetForm(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Merge") {
                    guard let target = accounts.first(where: { $0.id == targetID }) else { return }
                    do {
                        try CompassStore(context: context).merge(source, into: target)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .disabled(targetID == nil)
            }
        }
    }
}

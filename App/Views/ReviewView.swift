import AppKit
import Core
import SwiftData
import SwiftUI

/// Review, after Vult's Approvals: one list cleared from the top. New
/// transactions wait with Compass's guess at a category (changing it confirms
/// it and teaches the merchant's rule, as before); this month's money moved to
/// accounts Compass can't see waits to be filed as a transfer or not. Every
/// decision waits five seconds with Undo before it's saved (seam 48), and
/// anything still waiting is saved on leaving the page or quitting.
struct ReviewView: View {
    @Environment(\.modelContext) private var context
    @Environment(Navigator.self) private var navigator
    @FocusState private var queueFocused: Bool
    @State private var active: UUID?
    @State private var expanded: UUID?
    #if DEBUG
        @State private var openedDebugRow = false
    #endif
    @Query(
        filter: #Predicate<TransactionRecord> { $0.reviewPending == true || $0.category == nil },
        sort: \.dayOrdinal, order: .reverse)
    private var toReview: [TransactionRecord]
    @Query(sort: \AccountRecord.createdAt) private var accountRecords: [AccountRecord]
    @Query private var kindRecords: [CategoryKindRecord]
    /// One-sided suggestions marked as not transfers, by external ID (shared with Spending).
    @AppStorage("transfers.notTransfers") private var notTransfers = ""
    @State private var pending = PendingDecisions()
    /// Each waiting decision's transaction and the words its row says.
    @State private var decidedRows: [UUID: (transaction: Core.Transaction, words: String)] = [:]
    @State private var log: [(id: UUID, words: String, kept: Bool)] = []
    @State private var picked: Set<UUID> = []
    @State private var oneSided: [Core.Transaction] = []
    @State private var refiling = Refiling()
    @State private var now = Date.now

    var body: some View {
        let oneSidedIDs = Set(oneSided.map(\.id))
        let fresh = toReview.map(\.transaction).filter { !oneSidedIDs.contains($0.id) && !pending.isWaiting($0.id) }
        let transfers = oneSided.filter { !pending.isWaiting($0.id) }
        let confirmable = fresh.filter { $0.category != nil }
        let waitingCount = fresh.count + transfers.count
        let accounts = Dictionary(accountRecords.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        let ids = fresh.map(\.id) + transfers.map(\.id)
        let selected = confirmable.filter { picked.contains($0.id) }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    summary(waiting: waitingCount)

                    ForEach(pending.waiting) { item in waitingRow(item) }

                    if waitingCount == 0 && pending.waiting.isEmpty {
                        Text("You're all caught up.")
                            .font(Typeface.body)
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(maxWidth: .infinity)
                            .card(padding: Spacing.xl)
                    }

                    if !fresh.isEmpty {
                        group(
                            "New transactions", count: fresh.count,
                            note: "Confirm Compass's guess, or choose another category and Compass remembers it for that merchant."
                        ) {
                            ForEach(fresh) { transaction in
                                reviewRow(transaction, account: accounts[transaction.accountID] ?? "", transfer: false)
                                    .id(transaction.id)
                                if transaction.id != fresh.last?.id { Rule() }
                            }
                        }
                    }

                    if !transfers.isEmpty {
                        group(
                            "Transfers to check", count: transfers.count,
                            note:
                                "Money moved to or from an account Compass can't see. Filed ones leave your budget; ones that aren't transfers won't be suggested again."
                        ) {
                            ForEach(transfers) { transaction in
                                reviewRow(transaction, account: accounts[transaction.accountID] ?? "", transfer: true)
                                    .id(transaction.id)
                                if transaction.id != transfers.last?.id { Rule() }
                            }
                        }
                    }

                    if !log.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Decided").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                                .padding(.bottom, Spacing.xs)
                            ForEach(log, id: \.id) { entry in
                                HStack(spacing: Spacing.s) {
                                    Image(systemName: entry.kept ? "checkmark" : "xmark")
                                        .foregroundStyle(entry.kept ? Palette.onPace : Palette.inkSecondary)
                                        .frame(width: 20 * TextSize.current.scale)
                                    Text(entry.words).foregroundStyle(Palette.ink).lineLimit(1)
                                }
                                .font(Typeface.body)
                                .padding(.vertical, Spacing.s)
                                .overlay(alignment: .top) { Rule() }
                            }
                        }
                    }
                }
                .screenColumn()
            }
            .focusable()
            .focusEffectDisabled()
            .focused($queueFocused)
            .accessibilityLabel("Transactions waiting for review")
            .onChange(of: expanded) { _, id in
                #if DEBUG
                    if DebugSupport.openReviewName != nil, let id { proxy.scrollTo(id, anchor: .top) }
                #endif
            }
            .onKeyPress(.downArrow) { move(1, among: ids, proxy: proxy) }
            .onKeyPress(.upArrow) { move(-1, among: ids, proxy: proxy) }
            .onKeyPress(.return) {
                guard queueFocused, !navigator.isSearching, let active else { return .ignored }
                toggleDetails(active)
                return .handled
            }
            .onKeyPress(.space) {
                guard queueFocused, !navigator.isSearching, let active else { return .ignored }
                if confirmable.contains(where: { $0.id == active }) {
                    if picked.contains(active) { picked.remove(active) } else { picked.insert(active) }
                }
                return .handled
            }
            .onKeyPress(.escape) {
                guard queueFocused, !navigator.isSearching, expanded != nil else { return .ignored }
                withAnimation(Motion.change) { expanded = nil }
                return .handled
            }
            .onChange(of: ids, initial: true) { old, new in
                picked.formIntersection(new)
                if let expanded, !new.contains(expanded) { self.expanded = nil }
                if let active, new.contains(active) { return }
                let index = active.flatMap { old.firstIndex(of: $0) } ?? 0
                active = new.isEmpty ? nil : new[min(index, new.count - 1)]
            }
        }
        .background(Palette.canvas)
        .refiling(refiling)
        .onChange(of: [confirmable.count, selected.count], initial: true) { _, counts in
            navigator.reviewConfirmableCount = counts[0]
            navigator.reviewSelectedCount = counts[1]
        }
        .onChange(of: navigator.reviewConfirmRequest) { _, _ in decide(selected, .confirm) }
        .onChange(of: navigator.reviewConfirmAllRequest) { _, _ in decide(confirmable, .confirm) }
        .onChange(of: Set(toReview.compactMap(\.category)), initial: true) { _, inUse in refiling.inUse = inUse }
        .task(id: toReview.count) {
            loadOneSided()
            #if DEBUG
                if UserDefaults.standard.bool(forKey: "review.selectFirst"), picked.isEmpty,
                    let first = toReview.first(where: { $0.category != nil })
                {
                    picked.insert(first.id)
                }
                if !openedDebugRow, let name = DebugSupport.openReviewName,
                    let transaction = (toReview.map(\.transaction) + oneSided).first(where: { $0.merchant == name })
                {
                    openedDebugRow = true
                    active = transaction.id
                    expanded = transaction.id
                }
            #endif
        }
        // Saves each decision as its wait runs out, and moves the countdowns.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                now = .now
                save(pending.due(at: now))
            }
        }
        .onDisappear { save(pending.flush()) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            save(pending.flush())
        }
    }

    // MARK: Parts

    private func summary(waiting: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.m) {
                waitingText(waiting)
                Spacer(minLength: Spacing.s)
                keyboardHint
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                waitingText(waiting)
                keyboardHint
            }
        }
    }

    private func waitingText(_ waiting: Int) -> some View {
        Text(waiting == 0 ? "Nothing waiting" : "\(waiting.formatted()) waiting")
            .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
    }

    private var keyboardHint: some View {
        Text("↑↓ Move · Space Select · Return Details")
            .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .help("Click a row or tab to the review list. Space selects a categorized new transaction; Return opens its details; Esc closes them.")
    }

    private func move(_ offset: Int, among ids: [UUID], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard queueFocused, !navigator.isSearching, !ids.isEmpty else { return .ignored }
        let index = active.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        active = ids[min(max(index + offset, 0), ids.count - 1)]
        if let active { proxy.scrollTo(active, anchor: .center) }
        return .handled
    }

    private func toggleDetails(_ id: UUID) {
        active = id
        queueFocused = true
        withAnimation(Motion.change) { expanded = expanded == id ? nil : id }
    }

    private func reviewRow(_ transaction: Core.Transaction, account: String, transfer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if transfer { transferRow(transaction, account: account) } else { newRow(transaction, account: account) }
            if expanded == transaction.id {
                ReviewDetails(transaction: transaction, account: account, transferCandidate: transfer)
                    .padding(.bottom, Spacing.s)
            }
        }
        .padding(.horizontal, Spacing.s)
        .background(
            active == transaction.id ? Palette.selection : .clear,
            in: .rect(cornerRadius: Radius.control)
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(active == transaction.id ? .isSelected : [])
    }

    private func group<Rows: View>(_ title: String, count: Int, note: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                Text(title).font(Typeface.section).foregroundStyle(Palette.ink)
                Text(count.formatted()).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text(note).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) { rows() }
                .card(padding: Spacing.m)
        }
        .padding(.top, Spacing.s)
    }

    /// One line when there's room; in a narrow window the category drops
    /// under the merchant.
    private func newRow(_ transaction: Core.Transaction, account: String) -> some View {
        ViewThatFits(in: .horizontal) {
            newRowWide(transaction, account: account)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.s) {
                    pick(transaction)
                    RowMark(text: transaction.merchant, merchant: true)
                    detailButton(transaction, account: account)
                    amount(transaction)
                    confirmButton(transaction)
                }
                CategoryButton(transaction: transaction)
                    .font(Typeface.detail)
                    .padding(.leading, 30 * TextSize.current.scale + Spacing.s * 2 + 16)
            }
            .padding(.vertical, Spacing.s)
        }
    }

    private func detailButton(_ transaction: Core.Transaction, account: String) -> some View {
        Button {
            toggleDetails(transaction.id)
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: expanded == transaction.id ? "chevron.down" : "chevron.right")
                    .font(Typeface.caption).foregroundStyle(Palette.inkSecondary)
                    .frame(width: 12 * TextSize.current.scale)
                    .accessibilityHidden(true)
                names(transaction, account: account)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Details for \(transaction.merchant)")
        .accessibilityValue(expanded == transaction.id ? "Expanded" : "Collapsed")
        .accessibilityHint("Show the full bank description, current category check and budget treatment")
    }

    private func pick(_ transaction: Core.Transaction) -> some View {
        Toggle(
            "",
            isOn: Binding(
                get: { picked.contains(transaction.id) },
                set: { if $0 { picked.insert(transaction.id) } else { picked.remove(transaction.id) } })
        )
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(transaction.category == nil)
        .accessibilityLabel("Select \(transaction.merchant)")
    }

    private func confirmButton(_ transaction: Core.Transaction) -> some View {
        quick(
            "checkmark", help: transaction.category == nil ? "Choose a category first" : "Confirm \(transaction.category ?? "")",
            label: "Confirm \(transaction.merchant) as \(transaction.category ?? "uncategorized")"
        ) {
            decide([transaction], .confirm)
        }
        .disabled(transaction.category == nil)
    }

    private func newRowWide(_ transaction: Core.Transaction, account: String) -> some View {
        let scale = TextSize.current.scale
        return HStack(spacing: Spacing.s) {
            pick(transaction)
            RowMark(text: transaction.merchant, merchant: true)
            detailButton(transaction, account: account)
                .frame(minWidth: 160 * scale)
            CategoryButton(transaction: transaction)
                .font(Typeface.body)
                .frame(width: 170 * scale, alignment: .leading)
            amount(transaction)
            confirmButton(transaction)
        }
        .padding(.vertical, Spacing.s)
    }

    private func transferRow(_ transaction: Core.Transaction, account: String) -> some View {
        HStack(spacing: Spacing.s) {
            RowMark(text: transaction.merchant, symbol: "arrow.left.arrow.right")
            detailButton(transaction, account: account)
            amount(transaction)
            quick("xmark", help: "Not a transfer", label: "\(transaction.merchant) is not a transfer") {
                decide([transaction], .notTransfer)
            }
            quick("checkmark", help: "File as a transfer", label: "File \(transaction.merchant) as a transfer") {
                decide([transaction], .fileAsTransfer)
            }
        }
        .padding(.vertical, Spacing.s)
    }

    /// The merchant, then the day, account and the bank's own wording, the clue.
    private func names(_ transaction: Core.Transaction, account: String) -> some View {
        let day = transaction.day.startDate(in: .current).formatted(date: .abbreviated, time: .omitted)
        let statement = transaction.statement == transaction.merchant ? "" : transaction.statement
        return VStack(alignment: .leading, spacing: 1) {
            Text(transaction.merchant).font(Typeface.body).foregroundStyle(Palette.ink).lineLimit(1)
            Text([day, account, statement].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func amount(_ transaction: Core.Transaction) -> some View {
        Text(transaction.amount > 0 ? "+\(transaction.amount.dollars)" : (-transaction.amount).dollars)
            .font(Typeface.body).monospacedDigit()
            .foregroundStyle(transaction.amount > 0 ? Palette.ink : Palette.inkSecondary)
            .privateAmount()
            .frame(minWidth: 84 * TextSize.current.scale, alignment: .trailing)
    }

    private func quick(_ symbol: String, help: String, label: String, action: @escaping () -> Void) -> some View {
        let scale = TextSize.current.scale
        return Button(action: action) {
            Image(systemName: symbol)
                .font(Typeface.detail.weight(.semibold))
                .frame(width: 28 * scale, height: 28 * scale)
                .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Palette.rule))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.inkSecondary)
        .help(help)
        .accessibilityLabel(label)
    }

    /// A decision in its five seconds: what it'll do, a draining bar, Undo.
    private func waitingRow(_ item: PendingDecisions.Pending) -> some View {
        let scale = TextSize.current.scale
        let left = max(0, item.savesAt.timeIntervalSince(now)) / PendingDecisions.window
        return HStack(spacing: Spacing.s) {
            Image(systemName: item.decision == .notTransfer ? "xmark" : "checkmark")
                .foregroundStyle(Palette.inkSecondary)
            Text(decidedRows[item.id]?.words ?? "")
                .font(Typeface.body).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Capsule().fill(Palette.rule)
                .frame(width: 80 * scale, height: 3)
                .overlay(alignment: .leading) {
                    Capsule().fill(Palette.inkSecondary).frame(width: 80 * scale * left, height: 3)
                }
                .accessibilityHidden(true)
            Button("Undo") {
                pending.undo(item.id)
                decidedRows[item.id] = nil
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.card))
        .overlay(Hairline(cornerRadius: Radius.card))
    }

    // MARK: Deciding and saving

    private func decide(_ transactions: [Core.Transaction], _ decision: ReviewDecision) {
        for transaction in transactions {
            let words =
                switch decision {
                case .confirm: "\(transaction.merchant) as \(transaction.category ?? "uncategorized")"
                case .fileAsTransfer: "\(transaction.merchant) as a transfer"
                case .notTransfer: "\(transaction.merchant) isn't a transfer"
                }
            decidedRows[transaction.id] = (transaction, words)
            picked.remove(transaction.id)
        }
        pending.decide(transactions.map(\.id), decision, at: .now)
    }

    private func save(_ due: [PendingDecisions.Pending]) {
        guard !due.isEmpty else { return }
        let store = CompassStore(context: context)
        var dismissed = Set(notTransfers.split(separator: "\n").map(String.init))
        do {
            let confirming = due.filter { $0.decision == .confirm }.map(\.id)
            if !confirming.isEmpty { try store.confirm(confirming) }
            for item in due {
                guard let transaction = decidedRows[item.id]?.transaction else { continue }
                switch item.decision {
                case .confirm: break
                case .fileAsTransfer:
                    // Transfer-kind filing touches only that row: no merchant rule is learned.
                    _ = try store.file(transaction, as: TransferMatch.category)
                    if try store.kinds()[TransferMatch.category] == nil {
                        try store.setKind(.transfer, for: TransferMatch.category)
                    }
                case .notTransfer:
                    dismissed.insert(transaction.externalID)
                }
            }
        } catch {
            refiling.problem = error.localizedDescription
            // A failed save must not appear in Decided as a success.
            notTransfers = dismissed.sorted().joined(separator: "\n")
            for item in due { decidedRows[item.id] = nil }
            loadOneSided()
            return
        }
        notTransfers = dismissed.sorted().joined(separator: "\n")
        for item in due {
            if let row = decidedRows.removeValue(forKey: item.id) {
                log.insert((item.id, (item.decision == .notTransfer ? "Kept " : "Filed ") + row.words, item.decision != .notTransfer), at: 0)
            }
        }
        log = Array(log.prefix(20))
        loadOneSided()
    }

    /// This month's likely one-sided transfers, found across this month and
    /// last so a pair that spans the 1st still matches, as Spending finds them.
    private func loadOneSided() {
        let month = Month(Day(.now, in: .current))
        let from = month.adding(-1).firstDay.ordinal, first = month.firstDay.ordinal
        let descriptor = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.dayOrdinal >= from })
        let recent = ((try? context.fetch(descriptor)) ?? []).map(\.transaction)
        let kinds = Dictionary(
            kindRecords.compactMap { record in
                CategoryKind(rawValue: record.kindRaw).map { (record.category, $0) }
            }, uniquingKeysWith: { first, _ in first })
        let dismissed = Set(notTransfers.split(separator: "\n").map(String.init))
        let ids = TransferMatch.likelyOneSided(in: recent, kinds: kinds)
        oneSided = recent.filter { ids.contains($0.id) && $0.day.ordinal >= first && !dismissed.contains($0.externalID) }
            .sorted { $0.day > $1.day }
    }
}

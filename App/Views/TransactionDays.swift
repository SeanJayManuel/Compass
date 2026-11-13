import Core
import SwiftData
import SwiftUI

/// One day of transactions as Spending's month and the Transactions screen
/// list them, after Monarch's: the date and what the day spent and took in,
/// then each transaction's merchant, category, account and amount. A list
/// puts each day straight into its lazy stack, so only the days on screen
/// are built.
struct TransactionDayCard: View {
    let day: TransactionDay
    let accountNames: [UUID: String]
    /// For a row a goal paid for: "Paid from $5K Travel Fund".
    var goalNames: [UUID: String] = [:]
    var selectedID: UUID?
    var openDetails: ((Core.Transaction) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Text(Self.title(day.day))
                    .font(Typeface.detail.weight(.semibold)).foregroundStyle(Palette.inkSecondary)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                summary
            }
            .padding(.bottom, Spacing.s)
            ForEach(day.transactions) { transaction in
                Rule()
                TransactionRow(
                    transaction: transaction, account: accountNames[transaction.accountID] ?? "",
                    goal: transaction.paidFromGoal.flatMap { goalNames[$0] },
                    selected: selectedID == transaction.id, openDetails: openDetails)
            }
        }
        .card(padding: Spacing.m)
    }

    /// What the day spent and took in, in words, so a card payment or a
    /// transfer is never counted as spending.
    @ViewBuilder private var summary: some View {
        let header = Self.summary(of: day)
        let line = Text(header.words)
            .font(Typeface.detail).monospacedDigit().foregroundStyle(Palette.inkSecondary)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel(header.words)
        if header.hasAmounts { line.privateAmount() } else { line }
    }

    /// "$5.89 spent", "$20.00 refunded", "$400.00 from goals" (what a goal
    /// paid for, out of the budget), "+$2,600.00 in", joined with a dot. With neither, "Transfers only" when every transaction on the day
    /// is a transfer, else "Nothing spent": a deposit nobody has filed, a
    /// paycheck taken back, or refunds that cancel the charges aren't
    /// transfers. `hasAmounts` says whether there are figures to blur.
    static func summary(of day: TransactionDay) -> (words: String, hasAmounts: Bool) {
        var parts: [String] = []
        if day.spent > 0 {
            parts.append("\(day.spent.dollars) spent")
        } else if day.spent < 0 {
            parts.append("\((-day.spent).dollars) refunded")
        }
        if day.paidFromGoals > 0 { parts.append("\(day.paidFromGoals.dollars) from goals") }
        if day.received > 0 { parts.append("+\(day.received.dollars) in") }
        if !parts.isEmpty { return (parts.joined(separator: " · "), true) }
        return (day.transfersOnly ? "Transfers only" : "Nothing spent", false)
    }

    /// "Wednesday, October 21", with the year when it isn't this year's.
    private static func title(_ day: Day) -> String {
        let date = day.startDate(in: .current)
        let format = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        return day.year == Day(.now, in: .current).year ? date.formatted(format) : date.formatted(format.year())
    }
}

/// A transaction's line: the merchant (with the bank's statement under it
/// when that says something else), its category to refile, the account,
/// and the amount, money in green with a plus. On a narrow screen the line
/// stacks in two: the merchant and amount, then the category and account.
struct TransactionRow: View {
    let transaction: Core.Transaction
    let account: String
    /// The goal that paid for it, by name.
    var goal: String?
    var selected = false
    var openDetails: ((Core.Transaction) -> Void)?
    @Environment(\.rowDensity) private var density
    @State private var isEditing = false

    private var scale: CGFloat { TextSize.current.scale }

    var body: some View {
        Group {
            switch density {
            case .regular: regular
            case .compact: compact
            }
        }
        .font(Typeface.body)
        .padding(.vertical, Spacing.s)
        .background(selected ? Palette.selection : .clear, in: .rect(cornerRadius: Radius.control))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var regular: some View {
        RegularColumns(scale: scale, spacing: Spacing.m) {
            merchant(lines: 1).frame(maxWidth: .infinity, alignment: .leading)
            CategoryButton(transaction: transaction).frame(maxWidth: .infinity, alignment: .leading)
            Text(account).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            amount.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                merchant(lines: 2).frame(maxWidth: .infinity, alignment: .leading)
                amount.fixedSize()
            }
            HStack(spacing: Spacing.s) {
                CategoryButton(transaction: transaction).layoutPriority(1)
                Text(account).lineLimit(1).truncationMode(.middle).foregroundStyle(Palette.inkSecondary)
            }
            .font(Typeface.detail)
            // Lines up with the merchant's name, past its mark.
            .padding(.leading, 30 * scale + Spacing.s)
        }
    }

    private func merchant(lines: Int) -> some View {
        Button {
            if let openDetails { openDetails(transaction) } else { isEditing = true }
        } label: {
            HStack(alignment: .top, spacing: Spacing.s) {
                RowMark(text: transaction.merchant, merchant: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(transaction.merchant).foregroundStyle(Palette.ink).lineLimit(lines)
                    if !transaction.statement.isEmpty, transaction.statement != transaction.merchant {
                        Text(transaction.statement).font(Typeface.detail).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                    }
                    if let marks = TransactionDetails.marks(transaction, goal: goal) {
                        Group {
                            if transaction.owedBack > 0 || transaction.paidByGoal > 0 {
                                Text(marks).privateAmount()
                            } else {
                                Text(marks)
                            }
                        }
                        .font(Typeface.detail).foregroundStyle(Palette.inkSecondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Adds a note, or marks it a one-off, owed back or paid from a goal")
        .popover(isPresented: $isEditing, arrowEdge: .bottom) { TransactionDetails(transaction: transaction) }
    }

    private var amount: some View {
        Text(transaction.amount > 0 ? "+\(transaction.amount.dollars)" : (-transaction.amount).dollars)
            .monospacedDigit()
            .foregroundStyle(
                openDetails != nil
                    ? (transaction.amount > 0 ? Palette.ink : Palette.inkSecondary)
                    : (transaction.amount > 0 ? Palette.onPace : Palette.ink)
            )
            .privateAmount()
            .accessibilityLabel(transaction.amount > 0 ? "\(transaction.amount.dollars) in" : "\((-transaction.amount).dollars) out")
    }
}

/// The regular row's four columns: merchant, category, account and amount.
/// When the row is tight, the category gives way first, then the account, so
/// the merchant keeps its room (the stack's own `layoutPriority` would let
/// the merchant take everything, even in a wide window). The widths come
/// from the row's width alone, so the columns line up from row to row.
private struct RegularColumns: Layout {
    let scale: CGFloat
    let spacing: CGFloat

    private var amount: CGFloat { 110 * scale }
    /// What the merchant is given before the others give way: a typical name.
    private var merchantWants: CGFloat { 190 * scale }
    private var category: ClosedRange<CGFloat> { (90 * scale)...(190 * scale) }
    private var account: ClosedRange<CGFloat> { (60 * scale)...(170 * scale) }

    /// Merchant, category, account and amount widths in a row `width` wide.
    private func columns(for width: CGFloat) -> [CGFloat] {
        let free = max(width - amount - 3 * spacing, 0)
        var categoryWidth = category.upperBound, accountWidth = account.upperBound
        var short = merchantWants - (free - categoryWidth - accountWidth)
        if short > 0 {
            let fromCategory = min(short, categoryWidth - category.lowerBound)
            categoryWidth -= fromCategory
            short -= fromCategory
            accountWidth -= min(short, accountWidth - account.lowerBound)
        }
        return [max(free - categoryWidth - accountWidth, 0), categoryWidth, accountWidth, amount]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = merchantWants + category.upperBound + account.upperBound + amount + 3 * spacing
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
        let height =
            zip(subviews, columns(for: width))
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, columns(for: bounds.width)) {
            let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            subview.place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: width, height: height))
            x += width + spacing
        }
    }
}

extension Decimal {
    /// "+$4,876.60" or "−$123.45", to the cent.
    var signedDollars: String {
        self > 0 ? "+\(dollars)" : self < 0 ? "−\((-self).dollars)" : dollars
    }
}

/// A transaction's note, whether it's a one-off or owed back to them (what's
/// owed back isn't spending), and the goal that paid for it (out of the
/// budget, still spending). Saved when the editor closes.
struct TransactionDetails: View {
    let transaction: Core.Transaction
    var inPanel = false
    @Environment(\.modelContext) private var context
    @Query(sort: \GoalRecord.createdAt) private var goalRecords: [GoalRecord]
    @Query(sort: \AccountRecord.createdAt) private var accountRecords: [AccountRecord]
    @Query private var kindRecords: [CategoryKindRecord]
    @State private var note = ""
    @State private var oneOff = false
    @State private var reimbursable = false
    @State private var owed: Decimal?
    @State private var paidFrom: UUID?
    @State private var paidAmount: Decimal?

    /// The row's line under the merchant: the note, then the flags.
    static func marks(_ transaction: Core.Transaction, goal: String? = nil) -> String? {
        var parts: [String] = []
        if !transaction.note.isEmpty { parts.append(transaction.note) }
        if transaction.oneOff { parts.append("One-off") }
        if transaction.owedBack > 0 { parts.append("Owed back \(transaction.owedBack.dollars)") }
        if transaction.paidByGoal > 0 { parts.append("\(transaction.paidByGoal.dollars) from \(goal ?? "a goal")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var kinds: [String: CategoryKind] {
        Dictionary(
            kindRecords.compactMap { record in CategoryKind(rawValue: record.kindRaw).map { (record.category, $0) } },
            uniquingKeysWith: { first, _ in first })
    }

    /// Goals that can pay for it: active ones of cash accounts, and the one
    /// that already did, even if it's since been retired.
    private var payingGoals: [Goal] {
        let accounts = accountRecords.map(\.account)
        return goalRecords.map(\.goal).filter { GoalFunding.canPay($0, accounts: accounts) || $0.id == transaction.paidFromGoal }
    }

    /// Spending only, money out and not split, as `GoalFunding.pay` allows.
    private var canBePaidFromAGoal: Bool {
        transaction.amount < 0 && !transaction.isSplit
            && transaction.category.map { (kinds[$0] ?? CategoryKind.guess($0)) == .spending } ?? true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchant).font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(
                    "\(transaction.day.startDate(in: .current).formatted(date: .abbreviated, time: .omitted)) · \(abs(transaction.amount).dollars) \(transaction.amount < 0 ? "out" : "in")"
                )
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary).privateAmount()
            }
            if transaction.isSplit {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Split").font(Typeface.detail.weight(.semibold)).foregroundStyle(Palette.inkSecondary)
                    ForEach(transaction.splits, id: \.category) { part in
                        HStack {
                            Image(systemName: CategoryIcon.symbol(for: part.category)).foregroundStyle(Palette.inkSecondary).accessibilityHidden(true)
                            Text(part.category).foregroundStyle(Palette.ink)
                            Spacer()
                            Text(abs(part.amount).dollars).monospacedDigit().foregroundStyle(Palette.inkSecondary).privateAmount()
                        }
                        .font(Typeface.detail)
                    }
                    Text("Each part counts in its own category. Choosing one category files all of it that way.")
                        .font(Typeface.detail).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            TextField("Note", text: $note, axis: .vertical).lineLimit(2...5)
            Toggle("One-off", isOn: $oneOff)
            // A split isn't owed back; that's taken off before splitting.
            if transaction.amount < 0, !transaction.isSplit {
                Toggle("Someone owes me for it", isOn: $reimbursable)
                if reimbursable {
                    LabeledContent("Owed back") {
                        TextField("All of it", value: $owed, format: .currency(code: "USD"))
                            .multilineTextAlignment(.trailing).frame(width: 110 * TextSize.current.scale)
                    }
                    Text("What's owed back isn't counted as spending.").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                }
            }
            if canBePaidFromAGoal, !payingGoals.isEmpty || paidFrom != nil {
                Picker("Paid from", selection: $paidFrom) {
                    Text("My budget").tag(UUID?.none)
                    ForEach(payingGoals) { goal in Text(goal.name).tag(Optional(goal.id)) }
                }
                // Another goal starts from all of it, not the last one's amount.
                .onChange(of: paidFrom) {
                    paidAmount = paidFrom == transaction.paidFromGoal ? transaction.paidFromGoalAmount : nil
                }
                if paidFrom != nil {
                    LabeledContent("From the goal") {
                        TextField("All of it", value: $paidAmount, format: .currency(code: "USD"))
                            .multilineTextAlignment(.trailing).frame(width: 110 * TextSize.current.scale)
                    }
                    Text("Out of the budget, still counted in Spending. Move the money out of the goal's account to cover it.")
                        .font(Typeface.detail).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(inPanel ? 0 : Spacing.l)
        .frame(width: inPanel ? nil : 300 * TextSize.current.scale)
        .font(Typeface.body)
        .onAppear {
            note = transaction.note
            oneOff = transaction.oneOff
            reimbursable = transaction.reimbursable
            owed = transaction.reimbursableAmount
            paidFrom = transaction.paidFromGoal
            paidAmount = transaction.paidFromGoalAmount
        }
        .onDisappear(perform: save)
    }

    /// Only the note, flags and goal: the category is read fresh, so a refile since the row was drawn stands.
    private func save() {
        let store = CompassStore(context: context)
        guard let current = try? store.transaction(transaction.id) else { return }
        var edit = TransactionEdit(current)
        edit.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        edit.oneOff = oneOff
        edit.reimbursable = reimbursable && transaction.amount < 0
        edit.reimbursableAmount = edit.reimbursable ? owed.map { min(max($0, 0), -transaction.amount) }.flatMap { $0 > 0 ? $0 : nil } : nil
        var edited = current
        edit.apply(to: &edited)
        if let paidFrom, let goal = goalRecords.map(\.goal).first(where: { $0.id == paidFrom }) {
            // An amount past what's left after owed back is all of it.
            let amount = paidAmount.flatMap { $0 > 0 && $0 < -edited.spendingAmount ? $0 : nil }
            if let paid = try? GoalFunding.pay(edited, from: goal, amount: amount, accounts: accountRecords.map(\.account), kinds: kinds) {
                edit = TransactionEdit(paid)
            }
        } else {
            edit.paidFromGoal = nil
            edit.paidFromGoalAmount = nil
        }
        guard edit != TransactionEdit(current) else { return }
        SaveFailures.shared.attempt { try store.save(edit, for: transaction.id) }
    }
}

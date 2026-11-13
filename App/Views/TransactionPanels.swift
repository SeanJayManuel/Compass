import Charts
import Core
import SwiftUI

/// The existing transaction editor in the canvas, with context and a clear way back.
struct TransactionInspector: View {
    let transaction: Core.Transaction
    let account: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Text("Details").font(Typeface.section).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close transaction details")
                    .help("Close details and save changes")
            }
            Text(account).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            if !transaction.statement.isEmpty, transaction.statement != transaction.merchant {
                Text(transaction.statement).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                    .textSelection(.enabled)
            }
            CategoryButton(transaction: transaction).font(Typeface.body)
            Rule()
            TransactionDetails(transaction: transaction, inPanel: true)
            Text("Changes save when you leave these details.")
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            Button("Done", action: close).buttonStyle(.bordered)
        }
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Spacing.l)
    }
}

/// Money in and out, a month at a time, focused on this month: the
/// last few months with this one at the end, selected. Six months of bars,
/// money in green and money out red; the chosen month's figures and where
/// its money went under them. A month filter on the list chooses that month.
struct TransactionSummaryPanel: View {
    let summary: TransactionSummary?
    /// The list's month filter, if any.
    var focus: Month?
    static let monthsShown = 6
    @State private var chosen: Month?
    @State private var allCategories = false
    @AppStorage(HideAmounts.key) private var amountsHidden = false

    var body: some View {
        let months = window
        let selected = chosen ?? focus ?? months.last!
        let point = summary?.months.first { $0.month == selected } ?? .init(month: selected)
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Money in and out").font(Typeface.section).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                    .help("Transfers excluded; money out is net of refunds and what's owed back, including spending paid from goals.")
                Spacer(minLength: Spacing.s)
                Text(selected.name).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            if let summary {
                HStack(spacing: Spacing.l) {
                    figure("Money in", amount: point.income, color: Palette.onPace)
                    figure("Money out", amount: point.spending, color: Palette.failure)
                }
                bars(summary, months: months, selected: selected)
                Rule()
                Text("Where it went").font(Typeface.section).foregroundStyle(Palette.ink)
                if point.categories.isEmpty {
                    Text("No spending in \(selected.name).")
                        .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                } else {
                    let shown = allCategories ? point.categories : Array(point.categories.prefix(5))
                    ForEach(shown, id: \.category) { category in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                            CategoryGlyph(category: category.category)
                            Text(category.category).foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Text(category.amount.dollars).monospacedDigit().privateAmount()
                                .fixedSize()
                        }
                        .font(Typeface.detail)
                    }
                    if point.categories.count > 5 {
                        Button(allCategories ? "Show fewer categories" : "All \(point.categories.count) categories") {
                            withAnimation(Motion.change) { allCategories.toggle() }
                        }
                        .linkButton().font(Typeface.detail)
                    }
                }
            } else {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Reading transactions…").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: focus) { _, _ in chosen = nil }
    }

    /// Six months ending with this one, or with the filtered month.
    private var window: [Month] {
        let last = focus ?? Month(Day(.now, in: .current))
        return (0..<Self.monthsShown).reversed().map { last.adding(-$0) }
    }

    private func figure(_ name: String, amount: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.xs) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(name).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            Text(amount.wholeDollars).font(Typeface.figure).monospacedDigit().foregroundStyle(Palette.ink).privateAmount()
        }
        .accessibilityElement(children: .combine)
    }

    /// A pair of bars a month; clicking a month chooses it, the others dim.
    private func bars(_ summary: TransactionSummary, months: [Month], selected: Month) -> some View {
        let points = months.map { month in summary.months.first { $0.month == month } ?? .init(month: month) }
        let top = max(points.map { max($0.income, $0.spending) }.max() ?? 0, 1)
        let scale = TextSize.current.scale
        return VStack(spacing: Spacing.xs) {
            HStack(alignment: .bottom, spacing: Spacing.xs) {
                ForEach(points, id: \.month) { point in
                    let on = point.month == selected
                    Button {
                        chosen = point.month
                    } label: {
                        HStack(alignment: .bottom, spacing: 2) {
                            bar(point.income, top: top, color: Palette.onPace)
                            bar(point.spending, top: top, color: Palette.failure)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.vertical, 2)
                        .background(on ? Palette.hover : .clear, in: .rect(cornerRadius: 4))
                        .opacity(on ? 1 : 0.35)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(point.month.name)
                    .accessibilityValue(amountsHidden ? "Hidden" : "\(point.income.dollars) in, \(point.spending.dollars) out")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .frame(height: 96 * scale)
            HStack(spacing: Spacing.xs) {
                ForEach(points, id: \.month) { point in
                    Text(point.month.firstDay.startDate(in: .current).formatted(.dateTime.month(.abbreviated)))
                        .font(Typeface.caption)
                        .foregroundStyle(point.month == selected ? Palette.ink : Palette.inkSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func bar(_ amount: Decimal, top: Decimal, color: Color) -> some View {
        let fraction = max(0, min(1, (amount / top).chartValue))
        return GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2).fill(color)
                    .frame(height: max(amountsHidden ? 0 : geometry.size.height * fraction, amount > 0 ? 2 : 0))
            }
        }
        .frame(width: 8 * TextSize.current.scale)
    }
}

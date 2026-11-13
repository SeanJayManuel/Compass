import Core
import SwiftUI

/// One goal in the list: what it is, how far along it is (if the cache has
/// measured it yet), and whether it should play its once-only celebration.
struct GoalListEntry: Identifiable {
    let goal: Goal
    let progress: GoalProgress?
    let celebrate: Bool

    var id: UUID { goal.id }
}

/// The columns the list's header and every row share, so Pace (with what a
/// target date needs under it) and Gets there line up from one row to the next.
///
/// Each column has a range, and `GoalColumnsLayout` turns the width a row is
/// given into one width per column from those ranges alone, never from a row's
/// content. The minimums together fit inside `regularFrom` (the gaps, the `…`
/// menu and the rows' padding included), so a row never asks for more room
/// than the list measures: below that width the list switches its rows to
/// `.compact` instead.
enum GoalColumns {
    private static var scale: CGFloat { TextSize.current.scale }

    static var gap: CGFloat { Spacing.s }
    /// Name, progress (the bar and its percent), pace, gets there.
    static var columns: [(min: CGFloat, max: CGFloat)] {
        [
            (150 * scale, .infinity),
            (barMin + Spacing.s + percent, barMax + Spacing.s + percent),
            (104 * scale, 130 * scale),
            (96 * scale, 120 * scale)
        ]
    }
    /// The space between each column and the next. Gets there sits further from
    /// Pace, whose figures end at the column's right edge while Gets there
    /// starts at its left, so a smaller gap reads as one run of text. The
    /// minimums, the gaps (36) and the menu (24 × scale + 8) come to less than
    /// the width `regularFrom` sets aside.
    static var gaps: [CGFloat] { [gap, gap, Spacing.m + Spacing.xs] }
    static var barMin: CGFloat { 110 * scale }
    static var barMax: CGFloat { 260 * scale }
    /// Wide enough for "100%" on one line.
    static var percent: CGFloat { 44 * scale }
    /// The list's own width, inside its card, below which rows go `.compact`
    /// even when the screen's column is wide enough for other pages' rows:
    /// the name column's 150 × scale, the other three columns' minimums (362
    /// × scale), the gaps (36), the menu room (24 × scale + 8) and the rows'
    /// padding (16) come to 536 × scale + 60, which 700 × scale covers with room to spare from
    /// Small text up. The screen measures it, never a row.
    static var regularFrom: CGFloat { 700 * scale }
    /// The `…` menu, which floats over the row's trailing edge.
    static var menu: CGFloat { 24 * scale }
    /// Room kept at a row's trailing edge for the menu.
    static var menuRoom: CGFloat { menu + gap }
}

/// Lays out one row's five columns (see `GoalColumns`). The widths depend only
/// on the width proposed, so every row and the header agree. The layout never
/// reports less than its minimum, nor more than a proposal that's big enough,
/// so its size doesn't creep as the window changes the way an `HStack` of
/// ranged frames does.
private struct GoalColumnsLayout: Layout {
    /// Read from `GoalColumns` where the row is built, on the main actor.
    let columns: [(min: CGFloat, max: CGFloat)]
    let gaps: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = columnWidths(for: proposal.width)
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() where index < widths.count {
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: widths[index], height: nil)).height)
        }
        return CGSize(width: widths.reduce(0, +) + gaps.reduce(0, +), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(for: bounds.width)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() where index < widths.count {
            let width = widths[index]
            // The figure column (Pace) sits against its right edge.
            let trailing = index == 2
            subview.place(
                at: CGPoint(x: trailing ? x + width : x, y: bounds.midY),
                anchor: trailing ? .trailing : .leading,
                proposal: ProposedViewSize(width: width, height: nil))
            x += width + (index < gaps.count ? gaps[index] : 0)
        }
    }

    /// Everything starts at its minimum. Spare width goes first to pace and
    /// gets there (up to their maximum), then half to the bar (up to its
    /// maximum), and the rest to the name.
    private func columnWidths(for proposed: CGFloat?) -> [CGFloat] {
        var widths = columns.map(\.min)
        guard let proposed, proposed.isFinite else { return widths }
        var spare = proposed - widths.reduce(0, +) - gaps.reduce(0, +)
        for index in 2...3 where spare > 0 {
            let grow = min(spare, columns[index].max - widths[index])
            widths[index] += grow
            spare -= grow
        }
        guard spare > 0 else { return widths }
        let barGrow = min(spare / 2, columns[1].max - widths[1])
        widths[1] += barGrow
        spare -= barGrow
        widths[0] += spare
        return widths
    }
}

/// Active goals as one card of compact rows you can compare. Click a row for
/// the goal's page; the `…` menu (and right-click) edit or retire it.
struct GoalList: View {
    let entries: [GoalListEntry]
    let accountNames: [UUID: String]
    let today: Day
    var selectedID: UUID? = nil
    let open: (UUID) -> Void
    let edit: (Goal) -> Void
    let retire: (Goal) -> Void
    let celebrated: (UUID) -> Void
    @Environment(\.rowDensity) private var screenDensity
    /// The list's own width, nil until it's measured (the first pass draws
    /// the screen's density, then settles).
    @State private var listWidth: CGFloat?

    /// Compact when the screen says so, or when this table has less room than
    /// its five columns need (a 960 pt window is a regular screen width but a
    /// cramped table).
    private var density: RowDensity {
        if screenDensity == .compact { return .compact }
        if let listWidth, listWidth < GoalColumns.regularFrom { return .compact }
        return .regular
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if density == .regular { header }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 || density == .regular {
                    Rule().padding(.horizontal, Spacing.s)
                }
                row(for: entry)
            }
        }
        // The rows read the density settled here, not the screen's.
        .environment(\.rowDensity, density)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            listWidth = $0
        }
        // Rows pad themselves, so a row's hover wash reaches past its text.
        .padding(.horizontal, -Spacing.s)
        .card(padding: Spacing.l)
    }

    private var header: some View {
        GoalColumnsRow {
            Color.clear.frame(height: 1)
        } bar: {
            Text("Progress")
        } pace: {
            Text("Pace")
        } getsThere: {
            Text("Gets there")
        }
        .font(Typeface.detail)
        .foregroundStyle(Palette.inkSecondary)
        .padding(.horizontal, Spacing.s)
        .padding(.trailing, GoalColumns.menuRoom)
        .padding(.bottom, Spacing.s)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func row(for entry: GoalListEntry) -> some View {
        if let progress = entry.progress {
            let reading = GoalReading(goal: entry.goal, progress: progress, today: today)
            GoalListRow(
                goal: entry.goal,
                reading: reading,
                measure: reading.measure(accountNames: accountNames),
                celebrate: entry.celebrate,
                selected: entry.id == selectedID,
                open: { open(entry.id) },
                edit: { edit(entry.goal) },
                retire: { retire(entry.goal) },
                celebrated: { celebrated(entry.id) }
            )
        } else {
            // A goal the cache hasn't measured yet (just added or edited).
            HStack(spacing: Spacing.m) {
                ProgressView().controlSize(TextSize.current.scale > 1 ? .regular : .small)
                Text("Working out progress for \(entry.goal.name)…").font(Typeface.body).foregroundStyle(Palette.inkSecondary)
            }
            .padding(.vertical, Spacing.m)
            .padding(.horizontal, Spacing.s)
        }
    }
}

/// The header and rows lay their five columns out the same way.
private struct GoalColumnsRow<Name: View, Bar: View, Pace: View, GetsThere: View>: View {
    @ViewBuilder let name: Name
    @ViewBuilder let bar: Bar
    @ViewBuilder let pace: Pace
    @ViewBuilder let getsThere: GetsThere

    var body: some View {
        GoalColumnsLayout(columns: GoalColumns.columns, gaps: GoalColumns.gaps) {
            name
            bar
            pace
            getsThere
        }
    }
}

private struct GoalListRow: View {
    let goal: Goal
    let reading: GoalReading
    let measure: String
    let celebrate: Bool
    var selected = false
    let open: () -> Void
    let edit: () -> Void
    let retire: () -> Void
    let celebrated: () -> Void

    @Environment(\.rowDensity) private var density
    @AppStorage(HideAmounts.key) private var amountsHidden = false
    @State private var shownFraction: Double = 0
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            Group {
                if density == .regular { regular } else { compact }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, Spacing.s + Spacing.xs)
        .padding(.horizontal, Spacing.s)
        .background(selected ? Palette.selection : hovering ? Palette.hover : .clear, in: .rect(cornerRadius: Radius.control))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay(alignment: density == .regular ? .trailing : .topTrailing) {
            actions
                .padding(.trailing, Spacing.s)
                .padding(.top, density == .regular ? 0 : Spacing.s + Spacing.xs)
        }
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .accessibilityAction(named: "Open") { open() }
        .onAppear {
            if celebrate {
                // The one quiet moment: the bar fills, once.
                shownFraction = max(reading.barFraction - 0.15, 0)
                let fill = Motion.reduced ? Animation.easeOut(duration: 0.3) : .spring(duration: 0.9, bounce: 0)
                withAnimation(fill.delay(0.2)) { shownFraction = 1 }
                celebrated()
            } else {
                shownFraction = reading.barFraction
            }
        }
        .onChange(of: reading.barFraction) { _, new in
            withAnimation(Motion.change) { shownFraction = new }
        }
    }

    // MARK: Regular: five aligned columns

    private var regular: some View {
        GoalColumnsRow {
            identity
        } bar: {
            meter
        } pace: {
            // What a target date needs sits under the pace it's measured against.
            VStack(alignment: .trailing, spacing: 2) {
                figure(reading.pacePerMonth, label: reading.paceLabel)
                if let needs = reading.needsPerMonth {
                    Text("needs \(needs)").font(Typeface.detail).monospacedDigit().foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .accessibilityLabel(reading.needsLabel)
                        .privateAmount()
                }
            }
        } getsThere: {
            VStack(alignment: .leading, spacing: 2) {
                Text(reading.getsThere).font(Typeface.body).monospacedDigit().foregroundStyle(Palette.ink)
                if let note = reading.targetNote {
                    Text(note).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(reading.getsThereLabel)
            .privateAmount()
        }
        .padding(.trailing, GoalColumns.menuRoom)
    }

    /// The name, what it measures, and where it stands.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(goal.name).font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
            caption
            StatusLabel(text: reading.status.text, symbol: reading.status.symbol, tone: reading.status.tone)
        }
    }

    @ViewBuilder
    private var caption: some View {
        let text = Text(measure).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
        // Only a financial independence caption carries dollars.
        if reading.isFIRE { text.privateAmount() } else { text }
    }

    /// `label` names the column for VoiceOver ("Pace $795 a month"), since the
    /// header is hidden from it. It carries dollars, so `privateAmount` hides it
    /// with the figure.
    private func figure(_ text: String?, label: String) -> some View {
        Text(text ?? "—")
            .font(Typeface.body).monospacedDigit()
            .foregroundStyle(text == nil ? Palette.inkSecondary : Palette.ink)
            // A long figure shrinks a little before it ever breaks mid-number.
            .lineLimit(1).minimumScaleFactor(0.7)
            .accessibilityLabel(label)
            .privateAmount()
    }

    private var meter: some View {
        HStack(spacing: Spacing.s) {
            MeterBar(
                fraction: shownFraction, ticks: reading.minimumTick.map { [$0] } ?? [],
                tint: reading.isReached ? Palette.onPace : Palette.progress,
                label: meterLabel
            )
            .frame(minWidth: GoalColumns.barMin)
            Text("\(reading.percent)%")
                .font(Typeface.detail).monospacedDigit().foregroundStyle(Palette.ink)
                .lineLimit(1)
                .frame(width: GoalColumns.percent, alignment: .trailing)
        }
    }

    private var meterLabel: String {
        amountsHidden ? "\(reading.percent) percent" : "\(reading.percent) percent of \(reading.progress.target.wholeDollars)"
    }

    // MARK: Compact: stacked

    private var compact: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.name).font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
                    caption
                }
                Spacer(minLength: Spacing.s)
                StatusLabel(text: reading.status.text, symbol: reading.status.symbol, tone: reading.status.tone)
            }
            .padding(.trailing, GoalColumns.menu + Spacing.s)
            meter
            if let line = reading.compactLine {
                Text(line).font(Typeface.detail).monospacedDigit().foregroundStyle(Palette.inkSecondary).privateAmount()
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        RowActionsMenu(label: "Actions for \(goal.name)") { menuItems }
            .frame(width: GoalColumns.menu)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Edit Goal…", action: edit)
        if goal.status == .active { Button("Retire Goal…", action: retire) }
    }
}

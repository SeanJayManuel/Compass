import Core
import SwiftUI

/// Column widths shared by every budget card, scaled with the text size.
enum BudgetColumns {
    static var amount: CGFloat { 104 * TextSize.current.scale }
    static var remaining: CGFloat { 132 * TextSize.current.scale }
    /// The planned and actual figures in a narrow window's figures line,
    /// slimmer so the status pill can stay on the same line.
    static var compactPlanned: CGFloat { 92 * TextSize.current.scale }
    static var compactActual: CGFloat { 68 * TextSize.current.scale }
    /// A row's ⋯ menu; headers and totals keep the space empty.
    static var actions: CGFloat { 28 * TextSize.current.scale }
}

/// Something a budget row's ⋯ menu (and right-click) does.
struct BudgetRowAction {
    let title: String
    let run: () -> Void
}

struct GroupHeader: View {
    let title: String
    @Binding var collapsed: Bool
    @Environment(\.rowDensity) private var density

    var body: some View {
        HStack(spacing: Spacing.m) {
            Button {
                withAnimation(Motion.change) { collapsed.toggle() }
            } label: {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11 * TextSize.current.scale, weight: .semibold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .foregroundStyle(Palette.inkSecondary)
                    Text(title).font(Typeface.section).foregroundStyle(Palette.ink)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(collapsed ? "Shows its categories" : "Hides its categories")
            Spacer()
            // Compact rows label their own figures, so the columns have no headings.
            if density == .regular {
                Group {
                    Text("Planned").frame(width: BudgetColumns.amount, alignment: .trailing)
                    Text("Actual").frame(width: BudgetColumns.amount, alignment: .trailing)
                    Text("Remaining").frame(width: BudgetColumns.remaining, alignment: .trailing)
                    Color.clear.frame(width: BudgetColumns.actions, height: 1)
                }
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                .accessibilityHidden(true)
            }
        }
        .padding(.bottom, Spacing.s)
    }
}

/// One line: the category, its planned amount (a field, a figure or
/// nothing), what actually happened and what remains. In a narrow window
/// (`RowDensity.compact`) the figures drop to a second line, each with its
/// own label, instead of squeezing the name.
struct BudgetRow<Planned: View>: View {
    let name: String
    var note: String?
    var isTotal = false
    /// A line under a heading, set in from the total above it.
    var indented = false
    let actual: Decimal
    let remaining: Remaining?
    /// A category's row opens its charges for the month; a total's doesn't.
    var isOpen: Binding<Bool>?
    /// Its ⋯ menu: stop planning it, move it between fixed and flexible.
    var actions: [BudgetRowAction] = []
    @ViewBuilder let planned: () -> Planned
    @Environment(\.rowDensity) private var density

    /// A row with no planned amount (a flexible category) passes `EmptyView`.
    private var hasPlanned: Bool { Planned.self != EmptyView.self }

    var body: some View {
        Group {
            if density == .compact { compact } else { regular }
        }
        .font(isTotal ? Typeface.body.weight(.semibold) : Typeface.body)
        .padding(.leading, indented ? Spacing.m : 0)
        .padding(.vertical, Spacing.s)
        .contextMenu { actionButtons }
    }

    @ViewBuilder private var actionButtons: some View {
        ForEach(actions.indices, id: \.self) { index in
            Button(actions[index].title, action: actions[index].run)
        }
    }

    @ViewBuilder private var actionsMenu: some View {
        if !actions.isEmpty {
            RowActionsMenu(label: "Actions for \(name)") { actionButtons }
        }
    }

    private var regular: some View {
        HStack(spacing: Spacing.m) {
            label
                .layoutPriority(1)
                .frame(minWidth: 120 * TextSize.current.scale, alignment: .leading)
            Spacer(minLength: Spacing.s)
            if hasPlanned { planned().frame(width: BudgetColumns.amount, alignment: .trailing) }
            actualText.frame(width: BudgetColumns.amount, alignment: .trailing)
            Group {
                if let remaining { RemainingPill(remaining: remaining) } else { Color.clear.frame(height: 1) }
            }
            .frame(width: BudgetColumns.remaining, alignment: .trailing)
            Group {
                if actions.isEmpty { Color.clear.frame(height: 1) } else { actionsMenu }
            }
            .frame(width: BudgetColumns.actions, alignment: .trailing)
        }
    }

    @ViewBuilder private var compact: some View {
        if !hasPlanned, remaining?.label == nil {
            // Just a name and what it came to: one line.
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                label
                Spacer(minLength: Spacing.s)
                actualText
                // Kept even when empty, so amounts line up with rows that have a menu.
                Group {
                    if actions.isEmpty { Color.clear.frame(height: 1) } else { actionsMenu }
                }
                .frame(width: BudgetColumns.actions, alignment: .trailing)
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    label.frame(maxWidth: .infinity, alignment: .leading)
                    actionsMenu
                }
                // Planned and Actual have fixed widths and start at the left
                // edge, so they sit in the same columns on every row; the
                // pill keeps the right edge. A long pill goes under the
                // figures instead of pushing them, and at the largest text
                // in a narrow window Planned and Actual stack.
                ViewThatFits(in: .horizontal) {
                    compactFigures(.oneLine)
                    compactFigures(.pillBelow)
                    compactFigures(.stacked)
                }
            }
        }
    }

    private enum FiguresLayout { case oneLine, pillBelow, stacked }

    private func compactFigures(_ layout: FiguresLayout) -> some View {
        VStack(alignment: .trailing, spacing: Spacing.xs) {
            if layout == .stacked {
                Grid(alignment: .trailing, horizontalSpacing: Spacing.xs, verticalSpacing: Spacing.xs) {
                    if hasPlanned {
                        GridRow {
                            figureLabel("Planned").gridColumnAlignment(.leading)
                            planned().frame(width: BudgetColumns.compactPlanned, alignment: .trailing)
                        }
                    }
                    GridRow {
                        figureLabel("Actual").gridColumnAlignment(.leading)
                        actualText.frame(width: BudgetColumns.compactPlanned, alignment: .trailing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: Spacing.s) {
                    if hasPlanned {
                        HStack(spacing: Spacing.xs) {
                            figureLabel("Planned")
                            planned().frame(width: BudgetColumns.compactPlanned, alignment: .trailing)
                        }
                    }
                    HStack(spacing: Spacing.xs) {
                        figureLabel("Actual")
                        actualText.frame(width: BudgetColumns.compactActual, alignment: .trailing)
                    }
                    // The stack already puts its spacing either side of this.
                    Spacer(minLength: 0)
                    if layout == .oneLine, let remaining { RemainingPill(remaining: remaining) }
                }
            }
            if layout != .oneLine, let remaining { RemainingPill(remaining: remaining) }
        }
    }

    private var actualText: some View {
        Text(actual.budgetDollars).monospacedDigit().foregroundStyle(Palette.ink).privateAmount()
    }

    private func figureLabel(_ text: String) -> some View {
        Text(text).font(Typeface.caption).foregroundStyle(Palette.inkSecondary)
            .lineLimit(1).fixedSize()
    }

    /// The category's icon, then the name and under it a note, both
    /// wrapping by words. A total has no icon.
    @ViewBuilder private var label: some View {
        if let isOpen {
            Button {
                withAnimation(Motion.change) { isOpen.wrappedValue.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    CategoryGlyph(category: name)
                    nameAndNote
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen.wrappedValue ? "Hides this month's \(name) transactions" : "Shows this month's \(name) transactions")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                if !isTotal { CategoryGlyph(category: name) }
                nameAndNote
            }
        }
    }

    private var nameAndNote: some View {
        VStack(alignment: .leading, spacing: 1) {
            // The chevron follows the name, not a longer note under it.
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(name).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let isOpen {
                    Image(systemName: isOpen.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                        .accessibilityHidden(true)
                }
            }
            if let note {
                // A total's note carries amounts; a bill's is its usual day.
                if isTotal {
                    Text(note).font(Typeface.detail).foregroundStyle(Palette.inkSecondary).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .privateAmount()
                } else {
                    Text(note).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Charges sit under the category's name, past its icon, with amounts in
/// the Actual column (the right edge in compact rows, which have no columns).
struct ChargesUnderRow: ViewModifier {
    let indented: Bool
    @Environment(\.rowDensity) private var density

    func body(content: Content) -> some View {
        content
            .padding(.leading, (indented ? Spacing.m : 0) + 18 * TextSize.current.scale + Spacing.s)
            .padding(.trailing, density == .compact ? 0 : BudgetColumns.remaining + Spacing.m)
            .padding(.bottom, Spacing.s)
    }
}

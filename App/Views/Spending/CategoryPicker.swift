import Core
import SwiftData
import SwiftUI

/// Filing transactions from any list (Spending's month, Transactions, the
/// filing sheet): files the choice, matches a typed name to one already in
/// use, and offers to move the merchant's other charges along. A screen
/// owns one, hands it down with `.refiling(_:)`, and its rows use
/// `CategoryButton`.
@Observable
final class Refiling {
    /// Categories on screen that may have no merchant rule or plan yet, so
    /// the picker offers them too.
    var inUse: Set<String> = []
    var moving: Move?
    var problem: String?

    /// After a charge moves category, the same merchant's others still in
    /// the old one, offered to move along.
    struct Move: Identifiable {
        let transaction: Core.Transaction
        let from: String
        let to: String
        let count: Int
        var id: UUID { transaction.id }
    }

    /// Files `transaction` under `name`. A typed name is first matched to a
    /// category already in use ignoring case and spacing. When the
    /// merchant's rule changed and its other charges are still in the old
    /// category, offers to move them too: an Anthropic charge moved out of
    /// Miscellaneous brings last months' with it. A transfer files only this
    /// one, and a charge moved out of a transfer doesn't offer to move the
    /// merchant's other transfers, which are each their own occasion.
    func file(_ transaction: Core.Transaction, as name: String, typed: Bool = false, in context: ModelContext) {
        let store = CompassStore(context: context)
        do {
            let category = typed ? try store.existingCategory(matching: name) : name
            guard !category.isEmpty else { return }
            // Choosing the guess it already has confirms it.
            guard category != transaction.category else { return try store.confirm([transaction.id]) }
            let ruled = try store.file(transaction, as: category)
            guard ruled, let old = transaction.category,
                (try store.kinds()[old] ?? CategoryKind.guess(old)) != .transfer
            else { return }
            let count = try store.sameMerchant(as: transaction, in: old)
            if count > 0 { moving = Move(transaction: transaction, from: old, to: category, count: count) }
        } catch {
            problem = error.localizedDescription
        }
    }
}

extension View {
    /// Hands `refiling` to the rows below, with its alerts.
    func refiling(_ refiling: Refiling) -> some View {
        modifier(RefilingAlerts(refiling: refiling))
    }
}

private struct RefilingAlerts: ViewModifier {
    @Bindable var refiling: Refiling
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content
            .environment(refiling)
            .alert(item: $refiling.moving) { move in
                Alert(
                    title: Text(
                        move.count == 1
                            ? "Move the other \(move.transaction.merchant) charge too?"
                            : "Move the other \(move.count) \(move.transaction.merchant) charges too?"),
                    message: Text("\(move.count == 1 ? "It's" : "They're") still filed under \(move.from). New ones go to \(move.to) from now on."),
                    primaryButton: .default(Text(move.count == 1 ? "Move it" : "Move them")) {
                        do {
                            try CompassStore(context: context).refileSameMerchant(as: move.transaction, from: move.from, to: move.to)
                        } catch {
                            refiling.problem = error.localizedDescription
                        }
                    },
                    secondaryButton: .cancel(Text("Just this one"))
                )
            }
            .alert(
                "Couldn't file the transaction",
                isPresented: Binding(
                    get: { refiling.problem != nil }, set: { if !$0 { refiling.problem = nil } }
                )
            ) {
                Button("OK") { refiling.problem = nil }
            } message: {
                Text(refiling.problem ?? "")
            }
    }
}

/// A transaction's category as plain text: the category, or "Choose a
/// category" in amber when it has none. Clicking opens the picker, which is
/// only built then, so a long list costs no menus up front. Follows the
/// text size like the rest of the row.
struct CategoryButton: View {
    let transaction: Core.Transaction
    @Environment(Refiling.self) private var refiling
    @Environment(\.modelContext) private var context
    @State private var isPicking = false

    var body: some View {
        Button {
            isPicking = true
        } label: {
            HStack(spacing: 4) {
                if transaction.isSplit {
                    Image(systemName: "square.split.2x1").accessibilityHidden(true)
                } else if let category = transaction.category {
                    Image(systemName: CategoryIcon.symbol(for: category)).accessibilityHidden(true)
                }
                Text(transaction.isSplit ? "Split in \(transaction.splits.count)" : label).lineLimit(1)
                Image(systemName: "chevron.down").font(Typeface.detail.weight(.semibold)).imageScale(.small)
            }
            .foregroundStyle(transaction.category == nil ? Palette.behind : Palette.inkSecondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(transaction.isSplit ? label : "Category: \(transaction.category ?? "none")")
        .accessibilityHint("Chooses a category")
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            // Read when the picker opens, so rows don't redraw when it changes.
            CategoryPicker(current: transaction.category, inUse: { refiling.inUse }) { name, typed in
                isPicking = false
                // Once the popover has started closing, so the offer to move
                // the merchant's other charges can show.
                DispatchQueue.main.async { refiling.file(transaction, as: name, typed: typed, in: context) }
            }
        }
    }

    /// A split shows how many parts (its details list them) and says them
    /// aloud; choosing one category files all of it that way.
    private var label: String {
        guard transaction.isSplit else { return transaction.category ?? "Choose a category" }
        return "Split: " + transaction.splits.map(\.category).joined(separator: ", ")
    }
}

/// Every category to choose from, narrowed as they type; a name that isn't
/// there yet can be added. Read from the store when it opens.
private struct CategoryPicker: View {
    let current: String?
    let inUse: () -> Set<String>
    let choose: (_ name: String, _ typed: Bool) -> Void
    @Environment(\.modelContext) private var context
    @State private var categories: [String] = []
    @State private var text = ""
    /// The rows' own height. A popover sizes to what's inside it, and a
    /// scroll view asks for almost nothing, so without it the list is a sliver.
    @State private var listHeight: CGFloat = 0
    @FocusState private var focused: Bool

    private var scale: CGFloat { TextSize.current.scale }

    var body: some View {
        let typed = CategoryRules.tidy(text)
        let shown = typed.isEmpty ? categories : categories.filter { $0.localizedCaseInsensitiveContains(typed) }
        // The same name apart from case or spacing is the one in use, not a new one.
        let exact = CategoryRules.existing(typed, among: categories)

        VStack(alignment: .leading, spacing: 0) {
            TextField("Find or add a category", text: $text)
                .textFieldStyle(.plain)
                .font(Typeface.body)
                .focused($focused)
                .padding(Spacing.s)
                .onSubmit {
                    if let exact {
                        choose(exact, false)
                    } else if shown.count == 1 {
                        choose(shown[0], false)
                    } else if shown.isEmpty, !typed.isEmpty {
                        choose(typed, true)
                    }
                }
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !typed.isEmpty, exact == nil {
                        PickerRow(title: "Add “\(typed)”", systemImage: "plus") { choose(typed, true) }
                    }
                    ForEach(shown, id: \.self) { name in
                        PickerRow(title: name, systemImage: name == current ? "checkmark" : nil, category: name) { choose(name, false) }
                            .disabled(name == current)
                    }
                }
                .padding(.vertical, Spacing.xs)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
            }
            .frame(height: min(listHeight, 320 * scale))
            Rule()
            Text("Compass remembers the category for this merchant. A transfer is filed on its own.")
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Spacing.s)
        }
        .frame(width: 280 * scale)
        .onAppear {
            categories = Self.categories(store: CompassStore(context: context), inUse: inUse())
            focused = true
        }
    }

    /// Merchant rules, kinds and the plan (CompassStore.knownCategories),
    /// what's on screen, and Transfer, which has no rule of its own.
    private static func categories(store: CompassStore, inUse: Set<String>) -> [String] {
        ((try? store.knownCategories()) ?? []).union(inUse).union([TransferMatch.category])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

private struct PickerRow: View {
    let title: String
    let systemImage: String?
    /// The category this row picks, for its icon; nil for "Add".
    var category: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                Image(systemName: systemImage ?? "checkmark").opacity(systemImage == nil ? 0 : 1)
                    .foregroundStyle(Palette.inkSecondary).frame(width: 14 * TextSize.current.scale)
                if let category { CategoryGlyph(category: category) }
                Text(title).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Typeface.body)
            .padding(.horizontal, Spacing.s).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Palette.needleWash : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, Spacing.xs)
    }
}

import Core
import SwiftData
import SwiftUI

/// The search field and the two filters. Its own view because the row's
/// shape depends on `\.rowDensity`, which `screenColumn` sets for the
/// header's content, so the header can't read it itself.
///
/// Wide, one row: the search field takes what the menus leave, never less
/// than a usable prompt, and the menus give way before it does. Narrow (the
/// 720 pt window, or larger text), the search field has a row of its own
/// and the menus share the one below, so nothing is squeezed to an icon and
/// the column never asks for more width than the window has.
struct TransactionFilters: View {
    @Binding var text: String
    @Binding var category: CategoryFilter
    @Binding var month: Month?
    var searching: FocusState<Bool>.Binding
    let categories: [String]
    let months: [Month]
    @Environment(\.rowDensity) private var density

    private var scale: CGFloat { TextSize.current.scale }

    var body: some View {
        Group {
            switch density {
            case .regular:
                HStack(spacing: Spacing.m) {
                    search.frame(minWidth: 160 * scale)
                    categoryMenu.frame(minWidth: 120 * scale, idealWidth: 210 * scale, maxWidth: 210 * scale)
                    monthMenu.frame(minWidth: 110 * scale, idealWidth: 170 * scale, maxWidth: 170 * scale)
                }
            case .compact:
                VStack(spacing: Spacing.s) {
                    search
                    HStack(spacing: Spacing.m) {
                        categoryMenu.frame(maxWidth: .infinity)
                        monthMenu.frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .font(Typeface.body)
    }

    private var search: some View {
        SearchField(text: $text, prompt: "Merchant or statement", focused: searching)
    }

    // Menus holding the pickers, not pickers: a picker builds and measures
    // every item up front, and ten years of months took a third of the time
    // the screen takes to open. A menu builds its items when it opens. Wide, a
    // menu's width is fixed (its minimum gives way only when the row is tight),
    // so choosing doesn't shift the search field.
    private var categoryMenu: some View {
        FilterMenu(name: "Category", choice: category.title) {
            Picker("Category", selection: $category) {
                Text(CategoryFilter.any.title).tag(CategoryFilter.any)
                Text(CategoryFilter.unfiled.title).tag(CategoryFilter.unfiled)
                Divider()
                ForEach(categories, id: \.self) { Text($0).tag(CategoryFilter.named($0)) }
            }
            .pickerStyle(.inline).labelsHidden()
        }
    }

    private var monthMenu: some View {
        FilterMenu(name: "Month", choice: month?.name ?? "All time") {
            Picker("Month", selection: $month) {
                Text("All time").tag(Month?.none)
                Divider()
                ForEach(months, id: \.self) { Text($0.name).tag(Month?.some($0)) }
            }
            .pickerStyle(.inline).labelsHidden()
        }
    }
}

/// A filter beside the search field and drawn like it: the choice and a
/// chevron, opening a menu of the choices.
private struct FilterMenu<Choices: View>: View {
    let name: String
    let choice: String
    @ViewBuilder let choices: Choices

    var body: some View {
        Menu {
            choices
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(choice).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.inkSecondary)
            }
            .font(Typeface.body)
            .fieldChrome(focused: false)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel("\(name): \(choice)")
    }
}

// MARK: Reading off the main thread

private extension CategoryFilter {
    var title: String {
        switch self {
        case .any: "All categories"
        case .unfiled: "Needs a category"
        case .named(let name): name
        }
    }
}

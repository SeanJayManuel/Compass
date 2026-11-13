import Core
import SwiftData
import SwiftUI

/// The top bar's search field: opens the search panel, as ⌘K does from
/// anywhere. Narrow windows get the magnifier alone.
struct TopBarSearch: View {
    @Environment(Navigator.self) private var navigator
    @State private var hovering = false

    var body: some View {
        let scale = TextSize.current.scale
        ViewThatFits(in: .horizontal) {
            Button {
                navigator.isSearching = true
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                    Spacer(minLength: Spacing.s)
                    Text("⌘K")
                        .font(Typeface.caption.monospaced())
                        .padding(.horizontal, 5 * scale)
                        .padding(.vertical, 1 * scale)
                        .background(Palette.hover, in: .rect(cornerRadius: 4 * scale))
                }
                .font(Typeface.detail)
                .foregroundStyle(Palette.inkSecondary)
                .padding(.horizontal, 10 * scale)
                .frame(width: 200 * scale, height: 30 * scale)
                .background(hovering ? Palette.hover : Palette.surface, in: .rect(cornerRadius: 8 * scale))
                .overlay(Hairline(cornerRadius: 8 * scale))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Search everything (⌘K)")
            .accessibilityLabel("Search")

            TopBarButton(title: "Search (⌘K)", symbol: "magnifyingglass") { navigator.isSearching = true }
        }
    }
}

/// ⌘K from anywhere in the window, toggling the panel.
struct SearchCommands: Commands {
    let navigator: Navigator

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search Compass") { navigator.isSearching.toggle() }
                .keyboardShortcut("k")
        }
    }
}

/// The search panel over the window: one field, then matches grouped by kind
/// (seam 47). ↑↓ move, Return opens, Esc or a click outside closes. A match
/// opens its screen: a goal its page, a transaction Transactions searched
/// for its merchant.
struct QuickSearchPanel: View {
    @Environment(Navigator.self) private var navigator
    @Environment(SearchCache.self) private var cache
    @State private var text = ""
    /// Everything searchable, kept by the cache; nil until its first read is in.
    private var loaded: SearchLoaded? { cache.loaded }
    /// The matches for what's typed, found when the text (or what's loaded) changes, not on every draw.
    @State private var groups: [SearchGroup] = []
    /// The text `groups` were found for; behind `text` while a search runs.
    @State private var resultsFor: String?
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let scale = TextSize.current.scale
        let flat = groups.flatMap(\.items)
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture { close() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Palette.inkSecondary)
                    TextField("Accounts, categories, goals, habits, Playbook, notes, transactions", text: $text)
                        .textFieldStyle(.plain)
                        .font(Typeface.body)
                        .focused($focused)
                        .onSubmit {
                            // Return right after a keystroke opens a match for what's typed, not the last search's.
                            let current = resultsFor == text ? flat : loaded.map { QuickSearch.search(text, in: $0.index).flatMap(\.items) } ?? []
                            if current.indices.contains(selection) { open(current[selection]) }
                        }
                        .onKeyPress(.downArrow) {
                            selection = min(selection + 1, max(flat.count - 1, 0)); return .handled
                        }
                        .onKeyPress(.upArrow) {
                            selection = max(selection - 1, 0); return .handled
                        }
                        .onExitCommand { close() }
                }
                .padding(.horizontal, Spacing.m)
                .frame(height: 48 * scale)

                if !groups.isEmpty {
                    Rule()
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2 * scale) {
                                ForEach(groups, id: \.kind) { group in
                                    header(group)
                                    ForEach(group.items) { item in
                                        let index = flat.firstIndex(of: item) ?? 0
                                        row(item, selected: index == selection)
                                            .id(item.id)
                                            .onTapGesture { open(item) }
                                    }
                                }
                            }
                            .padding(Spacing.s)
                        }
                        .frame(maxHeight: 440 * scale)
                        .onChange(of: selection) { _, index in
                            if flat.indices.contains(index) { proxy.scrollTo(flat[index].id) }
                        }
                    }
                } else if !text.trimmingCharacters(in: .whitespaces).isEmpty, loaded != nil, resultsFor == text {
                    Rule()
                    Text("Nothing matches “\(text)”.")
                        .font(Typeface.detail)
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(Spacing.l)
                }
            }
            .frame(width: 600 * scale)
            .background(Palette.surface, in: .rect(cornerRadius: Radius.card))
            .overlay(Hairline(cornerRadius: Radius.card))
            .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
            .padding(.top, 64 * scale)
            .padding(.horizontal, Spacing.m)
        }
        // Brought up to date if anything was saved since its last read; until
        // then it searches what it has.
        .onAppear { cache.refreshIfNeeded() }
        .onChange(of: cache.version, initial: true) { if loaded != nil { Perf.mark("search.loaded") } }
        .onAppear {
            focused = true
            #if DEBUG
                if let typed = DebugSupport.openSearchText { text = typed }
            #endif
        }
        .onChange(of: text) { selection = 0 }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .perfSearchText)) { text = $0.object as? String ?? "" }
        #endif
        // Off the main thread; a newer keystroke cancels a search still running.
        .task(id: SearchInputs(text: text, version: cache.version)) {
            guard let index = loaded?.index else { return }
            let typed = text
            let found = await Self.search(typed, in: index)
            guard !Task.isCancelled else { return }
            groups = found
            resultsFor = typed
            Perf.mark("search.results")
        }
        .accessibilityAddTraits(.isModal)
    }

    private func header(_ group: SearchGroup) -> some View {
        HStack {
            Text(group.kind.groupName)
            Spacer()
            if group.more > 0 { Text("\(group.more) more") }
        }
        .font(Typeface.caption)
        .foregroundStyle(Palette.inkSecondary)
        .padding(.horizontal, Spacing.s)
        .padding(.top, Spacing.s)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: SearchItem, selected: Bool) -> some View {
        let scale = TextSize.current.scale
        let second = item.kind == .transaction ? (loaded?.lines[item.id]?.text ?? "") : item.detail
        return HStack(spacing: Spacing.s) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(selected ? Palette.needle : Palette.inkSecondary)
                .frame(width: 20 * scale)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Typeface.body)
                    .foregroundStyle(item.inactive ? Palette.inkSecondary : Palette.ink)
                    .lineLimit(1)
                if !second.isEmpty {
                    Text(second)
                        .font(Typeface.detail)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if item.inactive {
                Text(item.kind == .goal ? "Retired" : "Archived")
                    .font(Typeface.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .padding(.horizontal, Spacing.s)
        .frame(minHeight: 40 * scale)
        .background(selected ? Palette.selection : .clear, in: .rect(cornerRadius: 8 * scale))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func open(_ item: SearchItem) {
        switch item.kind {
        case .account: navigator.screen = .money
        case .category: navigator.screen = .spending
        case .goal:
            if let id = UUID(uuidString: item.id) { navigator.open(goal: id) } else { navigator.screen = .goals }
        case .habit: navigator.screen = .habits
        case .playbook: navigator.screen = .playbook
        case .note: navigator.screen = .notes
        case .transaction:
            navigator.transactionSearch = item.title
            navigator.screen = .transactions
        }
        close()
    }

    private func close() {
        navigator.isSearching = false
    }

    @concurrent nonisolated private static func search(_ text: String, in index: QuickSearchIndex) async -> [SearchGroup] {
        QuickSearch.search(text, in: index)
    }
}

private struct SearchInputs: Equatable {
    var text: String
    /// The cache's read, so a fresher one searches again.
    var version: Int
}

extension SearchKind {
    var groupName: String {
        switch self {
        case .account: "Accounts"
        case .category: "Categories"
        case .goal: "Goals"
        case .habit: "Habits"
        case .playbook: "Playbook"
        case .note: "Notes"
        case .transaction: "Transactions"
        }
    }

    var symbol: String {
        switch self {
        case .account: "building.columns"
        case .category: "tag"
        case .goal: "scope"
        case .habit: "flame"
        case .playbook: "book.closed"
        case .note: "note.text"
        case .transaction: "list.bullet.rectangle"
        }
    }
}

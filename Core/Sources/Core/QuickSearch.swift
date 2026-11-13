import Foundation

/// What a search result is, in the order the ⌘K panel lists its groups.
public enum SearchKind: Int, CaseIterable, Comparable, Sendable {
    case account, category, goal, habit, playbook, note, transaction

    public static func < (a: SearchKind, b: SearchKind) -> Bool { a.rawValue < b.rawValue }
}

/// One thing Compass keeps, as search sees it: a name, a second line also
/// searched (a statement, an account's institution), the day for a
/// transaction, and whether it's retired or archived.
public struct SearchItem: Hashable, Sendable, Identifiable {
    public var kind: SearchKind
    /// The record's id, or a category's name: what the app opens.
    public var id: String
    public var title: String
    public var detail: String
    public var day: Day?
    public var inactive: Bool

    public init(kind: SearchKind, id: String, title: String, detail: String = "", day: Day? = nil, inactive: Bool = false) {
        self.kind = kind
        self.id = id
        self.title = title
        self.detail = detail
        self.day = day
        self.inactive = inactive
    }
}

public struct SearchGroup: Hashable, Sendable {
    public var kind: SearchKind
    public var items: [SearchItem]
    /// Matches left out past the cap.
    public var more: Int
}

/// Seam 47: the search behind the top bar's field and ⌘K. Every word typed
/// must match the start of a word in the name or the second line, ignoring
/// case and accents. Within a kind, retired and archived things sit last,
/// then an exact name, then a name that starts with what's typed, then the
/// rest; transactions are newest first instead. Each kind is capped.
public enum QuickSearch {
    public static func search(_ text: String, in items: [SearchItem], limit: Int = 5) -> [SearchGroup] {
        search(text, in: QuickSearchIndex(items), limit: limit)
    }

    /// The same search over items whose words were folded once, so each
    /// keystroke only compares.
    public static func search(_ text: String, in index: QuickSearchIndex, limit: Int = 5) -> [SearchGroup] {
        let query = words(text)
        guard !query.isEmpty else { return [] }
        let typed = query.joined(separator: " ")

        // Each kind keeps only its first `limit` matches in order, and counts
        // the rest: sorting every match (thousands of transactions for one
        // letter) was most of a keystroke.
        var byKind: [SearchKind: (top: [(item: SearchItem, rank: Int)], count: Int)] = [:]
        for (position, entry) in index.entries.enumerated() {
            // A search a newer keystroke replaced stops early; its result is thrown away.
            if position % 2048 == 0, Task.isCancelled { return [] }
            guard query.allSatisfy({ word in entry.words.contains { $0.hasPrefix(word) } }) else { continue }
            let title = entry.title
            let match = (item: entry.item, rank: title == typed ? 0 : title.hasPrefix(typed) ? 1 : 2)
            var found = byKind[match.item.kind] ?? (top: [], count: 0)
            found.count += 1
            if found.top.count < limit || (found.top.last.map { comesFirst(match, $0) } ?? true) {
                // After any it ties with, so ties keep the order they came in.
                let at = found.top.firstIndex { comesFirst(match, $0) } ?? found.top.endIndex
                found.top.insert(match, at: at)
                if found.top.count > limit { found.top.removeLast() }
            }
            byKind[match.item.kind] = found
        }

        return SearchKind.allCases.compactMap { kind in
            guard let found = byKind[kind] else { return nil }
            return SearchGroup(kind: kind, items: found.top.map(\.item), more: max(0, found.count - limit))
        }
    }

    /// Active before retired or archived; transactions newest first; then an
    /// exact name, a leading one, the rest; then by name.
    private static func comesFirst(_ a: (item: SearchItem, rank: Int), _ b: (item: SearchItem, rank: Int)) -> Bool {
        if a.item.inactive != b.item.inactive { return !a.item.inactive }
        if a.item.kind == .transaction, a.item.day != b.item.day {
            return (a.item.day?.ordinal ?? .min) > (b.item.day?.ordinal ?? .min)
        }
        if a.rank != b.rank { return a.rank < b.rank }
        return a.item.title.localizedStandardCompare(b.item.title) == .orderedAscending
    }

    /// Lowercased, accents dropped, split at anything that isn't a letter or digit.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

/// Items ready to search: each one's name and second line folded and split
/// into words once, when the panel opens, rather than on every keystroke.
public struct QuickSearchIndex: Sendable {
    struct Entry: Sendable {
        var item: SearchItem
        /// The name's words joined, for ranking an exact or leading match.
        var title: String
        /// The name's words, then the second line's.
        var words: [String]
    }

    let entries: [Entry]

    public init(_ items: [SearchItem]) {
        entries = items.map { item in
            let titleWords = QuickSearch.words(item.title)
            return Entry(item: item, title: titleWords.joined(separator: " "), words: titleWords + QuickSearch.words(item.detail))
        }
    }
}

import Core
import Foundation
import Testing

/// Seam 47: the ⌘K search over everything Compass keeps.
@Suite struct QuickSearchTests {
    func item(_ kind: SearchKind, _ title: String, detail: String = "", day: Int? = nil, inactive: Bool = false) -> SearchItem {
        SearchItem(
            kind: kind, id: "\(kind)-\(title)-\(day ?? 0)", title: title, detail: detail,
            day: day.map { Day(year: 2026, month: 11, day: $0) }, inactive: inactive)
    }

    func titles(_ groups: [SearchGroup], _ kind: SearchKind) -> [String] {
        groups.first { $0.kind == kind }?.items.map(\.title) ?? []
    }

    @Test func typingNothingShowsNothing() {
        let items = [item(.account, "Chase Checking")]
        #expect(QuickSearch.search("", in: items).isEmpty)
        #expect(QuickSearch.search("   ", in: items).isEmpty)
    }

    @Test func matchingIgnoresCaseAndAccents() {
        let items = [item(.category, "Café"), item(.category, "Groceries")]
        #expect(titles(QuickSearch.search("CAFE", in: items), .category) == ["Café"])
    }

    @Test func matchesTheStartOfAnyWordOnly() {
        let items = [item(.account, "Chase Checking"), item(.account, "Ally Savings")]
        #expect(titles(QuickSearch.search("check", in: items), .account) == ["Chase Checking"])
        // "eck" is inside a word, not at its start.
        #expect(QuickSearch.search("eck", in: items).isEmpty)
    }

    @Test func everyWordTypedMustMatch() {
        let items = [item(.transaction, "Trader Joe's", day: 3), item(.transaction, "Trader Vic's", day: 4)]
        #expect(titles(QuickSearch.search("trader jo", in: items), .transaction) == ["Trader Joe's"])
    }

    @Test func theDetailLineCountsToo() {
        let items = [item(.transaction, "Landlord", detail: "ACH RENT PAYMENT", day: 1)]
        #expect(titles(QuickSearch.search("rent", in: items), .transaction) == ["Landlord"])
    }

    @Test func exactNamesRankAbovePartialOnes() {
        let items = [item(.goal, "Emergency fund top-up"), item(.goal, "Fund the trip"), item(.goal, "Fund")]
        #expect(titles(QuickSearch.search("fund", in: items), .goal) == ["Fund", "Fund the trip", "Emergency fund top-up"])
    }

    @Test func retiredAndArchivedSitLast() {
        let items = [item(.goal, "House", inactive: true), item(.goal, "House deposit")]
        #expect(titles(QuickSearch.search("house", in: items), .goal) == ["House deposit", "House"])
    }

    @Test func transactionsAreNewestFirst() {
        let items = [item(.transaction, "Uber", day: 2), item(.transaction, "Uber Eats", day: 9), item(.transaction, "Uber", day: 5)]
        #expect(
            QuickSearch.search("uber", in: items).first { $0.kind == .transaction }?.items.compactMap(\.day?.ordinal)
                == [9, 5, 2].map { Day(year: 2026, month: 11, day: $0).ordinal })
    }

    @Test func eachKindIsCapped() {
        let items = (1...9).map { item(.transaction, "Coffee", day: $0) }
        let group = QuickSearch.search("coffee", in: items, limit: 5).first { $0.kind == .transaction }
        #expect(group?.items.count == 5)
        #expect(group?.more == 4)
    }

    @Test func theCapKeepsTheFirstInOrderWhateverOrderTheyCameIn() {
        let days = [3, 8, 1, 9, 5, 2, 7, 4, 6]
        let transactions = days.map { item(.transaction, "Coffee", day: $0) }
        #expect(
            QuickSearch.search("coffee", in: transactions, limit: 3).first { $0.kind == .transaction }?.items.compactMap(\.day?.ordinal)
                == [9, 8, 7].map { Day(year: 2026, month: 11, day: $0).ordinal })
        let goals = [item(.goal, "Fund the trip"), item(.goal, "Fund", inactive: true), item(.goal, "Emergency fund"), item(.goal, "Fund")]
        #expect(titles(QuickSearch.search("fund", in: goals, limit: 2), .goal) == ["Fund", "Fund the trip"])
    }

    @Test func groupsComeInAFixedOrderAndEmptyOnesAreLeftOut() {
        let items = [item(.transaction, "Spotify", day: 1), item(.category, "Subscriptions"), item(.account, "Savings")]
        #expect(QuickSearch.search("s", in: items).map(\.kind) == [.account, .category, .transaction])
    }
}

import SwiftUI

/// A small SF Symbol for a category, in the sidebar's outline style, so a
/// list of categories scans by shape as well as by name. Matched on whole
/// words, so a renamed or new category ("Utilities", "Coffee") still finds
/// one; anything unmatched gets a tag.
enum CategoryIcon {
    static func symbol(for category: String) -> String {
        let words = Set(category.lowercased().split { !$0.isLetter }.map(String.init))
        return rules.first { $0.words.allSatisfy(words.contains) }?.symbol ?? "tag"
    }

    /// First match wins, so a rule needing more words comes before a
    /// shorter one that would also match ("gas electric" before "gas").
    private static let rules: [(words: [String], symbol: String)] = [
        // Home and bills
        (["rent"], "house"), (["mortgage"], "house"), (["home"], "house"), (["hoa"], "house"),
        (["gas", "electric"], "bolt"), (["electric"], "bolt"), (["electricity"], "bolt"), (["utilities"], "bolt"),
        (["water"], "drop"),
        (["internet"], "wifi"), (["cable"], "wifi"),
        (["phone"], "iphone"), (["mobile"], "iphone"),
        (["insurance"], "shield"),
        (["laundry"], "washer"),
        (["subscriptions"], "repeat"), (["subscription"], "repeat"), (["streaming"], "tv"),
        // Food
        (["groceries"], "basket"), (["grocery"], "basket"),
        (["coffee"], "cup.and.saucer"),
        (["eating"], "fork.knife"), (["restaurants"], "fork.knife"), (["dining"], "fork.knife"), (["food"], "fork.knife"),
        (["alcohol"], "wineglass"), (["bars"], "wineglass"),
        // Getting around
        (["gas"], "fuelpump"), (["fuel"], "fuelpump"),
        (["parking"], "parkingsign"), (["tolls"], "parkingsign"),
        (["transit"], "tram"), (["train"], "tram"),
        (["taxi"], "car"), (["ride"], "car"), (["uber"], "car"),
        (["auto", "maintenance"], "wrench.and.screwdriver"), (["maintenance"], "wrench.and.screwdriver"),
        (["car", "taxes"], "building.columns"), (["auto"], "car"), (["car"], "car"),
        (["travel"], "airplane"), (["vacation"], "airplane"), (["flights"], "airplane"), (["hotel"], "bed.double"),
        // Health and self
        (["medical"], "cross.case"), (["dental"], "cross.case"), (["health"], "cross.case"), (["pharmacy"], "pills"),
        (["fitness"], "dumbbell"), (["gym"], "dumbbell"),
        (["personal"], "person"), (["hair"], "scissors"),
        (["clothing"], "tshirt"),
        (["education"], "graduationcap"), (["books"], "book"),
        (["pets"], "pawprint"), (["pet"], "pawprint"),
        (["childcare"], "figure.and.child.holdinghands"),
        // Fun and giving
        (["entertainment"], "ticket"), (["recreation"], "ticket"), (["movies"], "ticket"),
        (["gambling"], "dice"),
        (["gifts"], "gift"), (["gift"], "gift"),
        (["charity"], "heart"), (["donations"], "heart"),
        (["shopping"], "bag"),
        // Money in
        (["paychecks"], "banknote"), (["paycheck"], "banknote"), (["salary"], "banknote"),
        (["interest"], "percent"),
        (["dividends"], "chart.line.uptrend.xyaxis"), (["capital"], "chart.line.uptrend.xyaxis"),
        (["reimbursement"], "arrow.uturn.backward"), (["refund"], "arrow.uturn.backward"),
        (["income"], "arrow.down.circle"),
        // Money moving
        (["credit", "card"], "creditcard"), (["fee"], "creditcard"), (["fees"], "creditcard"),
        (["taxes"], "building.columns"), (["tax"], "building.columns"),
        (["transfer"], "arrow.left.arrow.right"),
        (["buy"], "plus.circle"), (["sell"], "minus.circle"),
        (["adjustments"], "slider.horizontal.3"), (["adjustment"], "slider.horizontal.3"),
        (["miscellaneous"], "ellipsis.circle"), (["other"], "ellipsis.circle")
    ]

    /// Every symbol the rules use, for checking they exist.
    static var allSymbols: Set<String> { Set(rules.map(\.symbol)).union(["tag"]) }
}

/// The category's icon, sized to the text beside it. Decorative: the name
/// next to it says the same thing, so VoiceOver skips it.
struct CategoryGlyph: View {
    let category: String

    var body: some View {
        Image(systemName: CategoryIcon.symbol(for: category))
            .foregroundStyle(Palette.inkSecondary)
            .frame(width: 18 * TextSize.current.scale)
            .accessibilityHidden(true)
    }
}

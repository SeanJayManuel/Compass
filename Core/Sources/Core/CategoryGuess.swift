import Foundation

/// A category for a transaction with none, for them to confirm in review:
/// the merchant's own rule, else a known merchant inside its name or the
/// bank's text, else (for money out) a common merchant word.
public enum CategoryGuess {
    /// Evidence from today's rules, not a saved record of the original filing.
    public enum Evidence: Hashable, Sendable {
        case merchantRule
        case knownMerchant(phrase: String, inStatement: Bool)
        case commonWord(String)
    }

    public struct Match: Hashable, Sendable {
        public let category: String
        public let evidence: Evidence
    }

    public static func category(for transaction: Transaction, rules: CategoryRules, categories: Set<String>) -> String? {
        explanation(for: transaction, rules: rules, categories: categories)?.category
    }

    public static func explanation(for transaction: Transaction, rules: CategoryRules, categories: Set<String>) -> Match? {
        let incoming = transaction.amount > 0
        if let ruled = rules.category(for: transaction.merchant, incoming: incoming) {
            return Match(category: ruled, evidence: .merchantRule)
        }
        // Known merchants in this direction, by their key without the "+".
        let prefix = CategoryRules.key(merchant: "", incoming: incoming)
        let known = rules.all.compactMap { key, category -> (String, String)? in
            guard key.hasPrefix(prefix), incoming || !key.hasPrefix("+") else { return nil }
            let merchant = String(key.dropFirst(prefix.count))
            // Short names ("CA", "BP") turn up inside too many others.
            return merchant.count >= 4 ? (merchant, category) : nil
        }
        // "Taco Bell via DoorDash" is Taco Bell's before it's DoorDash's.
        let ordered = transaction.merchant.components(separatedBy: " via ").first.map { [$0] } ?? []
        let sources = (ordered + [transaction.merchant]).map { ($0, false) } + [(transaction.statement, true)]
        for (text, statement) in sources {
            if let match = longest(in: text, among: known) {
                return Match(category: match.1, evidence: .knownMerchant(phrase: match.0, inStatement: statement))
            }
        }
        guard !incoming else { return nil }
        let words = commonWords.compactMap { word, names -> (String, String)? in
            names.lazy.compactMap { CategoryRules.existing($0, among: categories) }.first.map { (word, $0) }
        }
        return longest(in: transaction.merchant + " " + transaction.statement, among: words).map {
            Match(category: $0.1, evidence: .commonWord($0.0))
        }
    }

    /// The longest whole-word phrase and its category, with stable ties.
    private static func longest(in text: String, among phrases: [(String, String)]) -> (String, String)? {
        let padded = " \(Merchant.key(text)) "
        return
            phrases
            .filter { padded.contains(" \($0.0) ") }
            .max { a, b in (a.0.count, b.0) < (b.0.count, a.0) }
    }

    /// Common merchant words, each with the category names it may go under,
    /// their own (Monarch's) first. Keys as `Merchant.key` makes them.
    private static let commonWords: [(String, [String])] = {
        let table: [([String], [String])] = [
            (
                [
                    "restaurant", "pizza", "pizzeria", "cafe", "coffee", "starbucks", "mcdonald s", "chipotle", "taco",
                    "burger", "grill", "sushi", "bakery", "doordash", "grubhub", "uber eats", "postmates", "kitchen", "diner"
                ],
                ["Eating Out", "Restaurants & Bars", "Restaurants", "Dining", "Food & Dining"]
            ),
            (
                [
                    "grocery", "groceries", "supermarket", "trader joe s", "whole foods", "safeway", "kroger", "aldi",
                    "wegmans", "publix", "instacart", "costco"
                ],
                ["Groceries"]
            ),
            (
                ["shell", "chevron", "exxon", "exxonmobil", "mobil", "sunoco", "texaco", "valero", "arco", "fuel", "gas station"],
                ["Gas", "Gas & Fuel", "Fuel"]
            ),
            (["uber", "lyft", "taxi", "cab"], ["Taxi & Ride Shares", "Rideshare"]),
            (["parking", "parkmobile", "toll", "e zpass", "ezpass", "fastrak"], ["Parking & Tolls"]),
            (["mta", "metro", "transit", "bart", "amtrak"], ["Public Transit"]),
            (
                ["airbnb", "airlines", "airline", "hotel", "marriott", "hilton", "hyatt", "expedia", "delta", "united"],
                ["Travel & Vacation", "Travel"]
            ),
            (
                ["netflix", "spotify", "hulu", "disney plus", "hbo", "cinema", "theatre", "theater", "amc", "steam"],
                ["Entertainment & Recreation", "Entertainment"]
            ),
            (["gym", "fitness", "equinox", "peloton", "planet fitness"], ["Fitness"]),
            (
                ["pharmacy", "cvs", "walgreens", "dental", "dentist", "clinic", "medical", "hospital"],
                ["Medical / Dental", "Medical", "Healthcare"]
            ),
            (["amazon", "target", "walmart", "best buy", "ikea", "etsy", "ebay", "apple store"], ["Shopping"]),
            (["laundry", "laundromat"], ["Laundry"]),
            (["comcast", "xfinity", "spectrum", "verizon fios", "internet"], ["Internet & Cable"])
        ]
        return table.flatMap { words, names in words.map { ($0, names) } }
    }()
}

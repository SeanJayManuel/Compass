import Foundation

/// A rule or reason worth keeping for Claude, the "why" that isn't data
/// anywhere else in Compass: "Keep a month of spending in checking because…".
/// Never figures other tools already give (balances, pay, budget amounts).
public struct Note: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    /// Money, Goals, Career, Life, or their own.
    public var topic: String
    public var title: String
    /// Short text, no formatting.
    public var body: String
    public var updatedAt: Date

    public init(id: UUID = UUID(), topic: String, title: String, body: String, updatedAt: Date) {
        self.id = id
        self.topic = topic
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
    }
}

/// Notes by topic (seam 42).
public enum Notes {
    /// The topics offered first, in this order; others follow A to Z.
    public static let topics = ["Money", "Goals", "Career", "Life"]

    /// A known topic however it's typed ("money" is Money), else one of
    /// `existing`'s topics however it's typed, else as given, trimmed.
    public static func topic(_ text: String, existing: [Note] = []) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (topics + existing.map(\.topic)).first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
    }

    /// Known topics first, then others A to Z, each newest first; only
    /// `topic`, ignoring case, when one is given.
    public static func grouped(_ notes: [Note], topic wanted: String? = nil) -> [(topic: String, notes: [Note])] {
        let kept = wanted.map { wanted in notes.filter { $0.topic.caseInsensitiveCompare(Self.topic(wanted)) == .orderedSame } } ?? notes
        let byTopic = Dictionary(grouping: kept) { topic($0.topic) }
        let others = byTopic.keys.filter { !topics.contains($0) }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return (topics.filter { byTopic[$0] != nil } + others).map { name in
            (name, byTopic[name, default: []].sorted { $0.updatedAt > $1.updatedAt })
        }
    }
}

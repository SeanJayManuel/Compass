import Core
import Foundation
import Testing

/// Seam 42: notes for Claude, grouped by topic.
@Suite struct NotesTests {
    func at(_ day: Int) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400) }

    @Test func notesGroupByTopicKnownOnesFirstThenOthersAToZNewestFirstInEach() {
        let rent = Note(topic: "Money", title: "Rent", body: "Paid from checking", updatedAt: at(1))
        let cash = Note(topic: "Money", title: "Cash buffer", body: "Keep a month", updatedAt: at(3))
        let promo = Note(topic: "Career", title: "Promotion", body: "Ask in spring", updatedAt: at(2))
        let health = Note(topic: "Health", title: "Sleep", body: "Lights out by 11", updatedAt: at(2))
        let books = Note(topic: "Books", title: "Reading", body: "One a month", updatedAt: at(4))
        let groups = Notes.grouped([rent, health, promo, books, cash])
        #expect(groups.map(\.topic) == ["Money", "Career", "Books", "Health"])
        #expect(groups[0].notes.map(\.title) == ["Cash buffer", "Rent"])
    }

    @Test func aTopicFilterIgnoresCase() {
        let rent = Note(topic: "Money", title: "Rent", body: "Paid from checking", updatedAt: at(1))
        let promo = Note(topic: "Career", title: "Promotion", body: "Ask in spring", updatedAt: at(2))
        #expect(Notes.grouped([rent, promo], topic: "career").map(\.topic) == ["Career"])
        #expect(Notes.grouped([rent, promo], topic: "Travel").isEmpty)
    }

    @Test func aKnownTopicIsMatchedIgnoringCaseAndOthersKeepTheirWords() {
        #expect(Notes.topic(" money ") == "Money")
        #expect(Notes.topic("LIFE") == "Life")
        #expect(Notes.topic(" health ") == "health")
        // A topic another note has keeps that note's spelling, so it stays one group.
        let sleep = Note(topic: "Health", title: "Sleep", body: "Lights out by 11", updatedAt: at(2))
        #expect(Notes.topic("HEALTH", existing: [sleep]) == "Health")
    }
}

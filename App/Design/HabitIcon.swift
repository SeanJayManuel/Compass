import SwiftUI

/// An SF Symbol for a habit, drawn in its round mark instead of initials
/// (exercise gets a dumbbell, meditation something calm, a language a
/// book). Matched on the start of each word in the habit's name, so
/// "Meditating" and "Meditate" both find one; anything unmatched gets a flame,
/// the Habits screen's own icon.
enum HabitIcon {
    static func symbol(for title: String) -> String {
        let words = title.lowercased().split { !$0.isLetter }.map(String.init)
        // "Work out" is two words; read it as one.
        if words.joined().contains("workout") { return "dumbbell" }
        return rules.first { rule in words.contains { $0.hasPrefix(rule.stem) } }?.symbol ?? "flame"
    }

    /// First match wins, so the likelier meaning comes first.
    private static let rules: [(stem: String, symbol: String)] = [
        // Body
        ("exercis", "dumbbell"), ("workout", "dumbbell"), ("lift", "dumbbell"), ("gym", "dumbbell"),
        ("strength", "dumbbell"), ("push", "dumbbell"), ("pull", "dumbbell"),
        ("run", "figure.run"), ("jog", "figure.run"), ("cardio", "figure.run"),
        ("walk", "figure.walk"), ("steps", "figure.walk"), ("hike", "figure.hiking"),
        ("swim", "figure.pool.swim"), ("bike", "bicycle"), ("cycl", "bicycle"),
        ("stretch", "figure.flexibility"), ("yoga", "figure.yoga"), ("mobility", "figure.flexibility"),
        // Mind
        ("medita", "figure.mind.and.body"), ("mindful", "figure.mind.and.body"), ("breath", "wind"),
        ("pray", "hands.sparkles"), ("gratitude", "heart"), ("journal", "book.closed"),
        // Learning
        ("french", "book"), ("spanish", "book"), ("german", "book"), ("italian", "book"),
        ("japanese", "book"), ("mandarin", "book"), ("language", "character.bubble"), ("duolingo", "character.bubble"),
        ("read", "book"), ("book", "book"), ("study", "graduationcap"), ("learn", "graduationcap"),
        ("writ", "pencil"), ("code", "chevron.left.forwardslash.chevron.right"), ("program", "chevron.left.forwardslash.chevron.right"),
        ("guitar", "guitars"), ("piano", "pianokeys"), ("music", "music.note"), ("practi", "music.note"),
        // Day to day
        ("water", "drop"), ("hydrat", "drop"), ("sleep", "bed.double"), ("bed", "bed.double"),
        ("phone", "iphone.slash"), ("screen", "iphone.slash"), ("social", "iphone.slash"),
        ("cook", "frying.pan"), ("meal", "fork.knife"), ("protein", "fork.knife"), ("eat", "fork.knife"),
        ("vitamin", "pills"), ("supplement", "pills"), ("medic", "pills"),
        ("floss", "mouth"), ("teeth", "mouth"), ("skin", "drop.circle"),
        ("clean", "sparkles"), ("tidy", "sparkles"), ("laundry", "washer"),
        ("sun", "sun.max"), ("outside", "sun.max"),
        ("budget", "dollarsign.circle"), ("save", "dollarsign.circle"), ("spend", "dollarsign.circle"),
        ("call", "phone"), ("family", "person.2"), ("friend", "person.2"),
        ("alcohol", "wineglass"), ("drink", "wineglass")
    ]

    /// Every symbol the rules use, for checking they exist.
    static var allSymbols: Set<String> { Set(rules.map(\.symbol)).union(["flame"]) }
}

import AppKit
import Core
import SwiftData
import SwiftUI

enum Screen: Hashable {
    /// New transactions and transfers to check, cleared from the top.
    case review
    /// Net worth and the accounts under it.
    case money
    case goals
    case spending
    case transactions
    /// This week's habits, the quarter's goals and the vision, at a glance.
    case life
    /// How consistent each habit has been, day by day.
    case habits
    /// What works for them: sizes, things they rebuy, routines.
    case playbook
    /// Their rules and reasons, kept for Claude.
    case notes
    case settings

    /// What VoiceOver and the window call it.
    var title: String {
        switch self {
        case .money: "Money overview"
        case .life: "Life overview"
        default: rowTitle
        }
    }

    /// Its name in the sidebar and the top bar, under its section.
    var rowTitle: String {
        switch self {
        case .money, .life: "Overview"
        case .review: "Review"
        case .goals: "Goals"
        case .spending: "Spending"
        case .transactions: "Transactions"
        case .habits: "Habits"
        case .playbook: "Playbook"
        case .notes: "Notes"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .money, .life: "square.grid.2x2"
        case .review: "tray"
        case .goals: "scope"
        case .spending: "cart"
        case .transactions: "list.bullet.rectangle"
        case .habits: "flame"
        case .playbook: "book.closed"
        case .notes: "note.text"
        case .settings: "slider.horizontal.3"
        }
    }

    /// The sidebar group it sits in.
    var section: String {
        switch self {
        case .money, .goals, .spending, .transactions, .review: "Money"
        case .life, .habits, .playbook: "Life"
        case .notes: "Context"
        case .settings: "Compass"
        }
    }

    /// The money overview, spending, transactions and goals: the screens
    /// with the add, import and sync buttons.
    var isMoney: Bool {
        switch self {
        case .money, .goals, .spending, .transactions, .review: true
        case .life, .habits, .playbook, .notes, .settings: false
        }
    }
}

/// Which screen the sidebar shows. Shared so the debug performance run can
/// drive it.
@Observable
final class Navigator {
    var screen: Screen? = .money
    /// A goal to open on Goals' next visit, set by the money overview's goal rows.
    var goalToOpen: UUID?
    /// Whether the search panel (⌘K) is up.
    var isSearching = false
    /// A merchant for Transactions to search for on its next visit, from the search panel.
    var transactionSearch: String?
    /// Presentation shared by Spending and its controls in the frame.
    var spendingMonth = Month(Day(.now, in: .current))
    var spendingAction: SpendingAction?
    var newGoalRequest = 0
    var newHabitRequest = 0
    var newPlaybookRequest = 0
    var newNoteRequest = 0
    /// Review publishes counts; the frame requests its existing batch actions.
    var reviewConfirmableCount = 0
    var reviewSelectedCount = 0
    var reviewConfirmRequest = 0
    var reviewConfirmAllRequest = 0

    static let order: [Screen] = [.review, .life, .habits, .playbook, .money, .spending, .transactions, .goals, .notes, .settings]

    func open(goal id: UUID) {
        goalToOpen = id
        screen = .goals
    }

    func step(_ offset: Int) {
        let index = Self.order.firstIndex(of: screen ?? .money) ?? 0
        screen = Self.order[min(max(index + offset, 0), Self.order.count - 1)]
    }
}

/// Commands from the top bar; Spending owns the sheets and their saved data.
enum SpendingAction: Equatable { case editBudget, fromHistory, categories }

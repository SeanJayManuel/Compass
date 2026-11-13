import Foundation

/// What Review does with a transaction once its wait is over.
public enum ReviewDecision: Hashable, Sendable {
    /// Keep the category it has; its merchant's rule follows.
    case confirm
    /// File a one-sided transfer under Transfer.
    case fileAsTransfer
    /// A one-sided suggestion that isn't a transfer: never suggest it again.
    case notTransfer
}

/// Seam 48: Review's decisions wait `window` seconds before they're saved,
/// so a mis-click can be undone. Deciding the same transaction again
/// replaces its decision and restarts its wait; a batch keeps a wait each;
/// leaving the page saves whatever is still waiting.
public struct PendingDecisions: Sendable {
    public static let window: TimeInterval = 5

    public struct Pending: Hashable, Sendable, Identifiable {
        public let id: UUID
        public let decision: ReviewDecision
        public let decidedAt: Date
        public var savesAt: Date { decidedAt.addingTimeInterval(PendingDecisions.window) }
    }

    /// Oldest first.
    public private(set) var waiting: [Pending] = []

    public init() {}

    public func isWaiting(_ id: UUID) -> Bool { waiting.contains { $0.id == id } }

    public mutating func decide(_ id: UUID, _ decision: ReviewDecision, at now: Date) {
        waiting.removeAll { $0.id == id }
        waiting.append(Pending(id: id, decision: decision, decidedAt: now))
    }

    public mutating func decide(_ ids: [UUID], _ decision: ReviewDecision, at now: Date) {
        for id in ids { decide(id, decision, at: now) }
    }

    /// False when it isn't waiting (never decided, or already saved).
    @discardableResult
    public mutating func undo(_ id: UUID) -> Bool {
        guard isWaiting(id) else { return false }
        waiting.removeAll { $0.id == id }
        return true
    }

    /// The decisions whose wait is over, oldest first, taken off the list.
    public mutating func due(at now: Date) -> [Pending] {
        let ready = waiting.filter { $0.savesAt <= now }
        waiting.removeAll { $0.savesAt <= now }
        return ready
    }

    /// Everything still waiting, oldest first, for leaving the page or quitting.
    public mutating func flush() -> [Pending] {
        defer { waiting = [] }
        return waiting
    }
}

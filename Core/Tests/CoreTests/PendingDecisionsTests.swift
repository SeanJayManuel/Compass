import Core
import Foundation
import Testing

/// Seam 48: Review's decisions wait five seconds, with Undo, before they're saved.
@Suite struct PendingDecisionsTests {
    let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let a = UUID(), b = UUID(), c = UUID()

    @Test func aDecisionIsNotSavedBeforeItsFiveSeconds() {
        var pending = PendingDecisions()
        pending.decide(a, .confirm, at: start)
        let r1 = pending.due(at: start.addingTimeInterval(4.9))
        #expect(r1.isEmpty)
        #expect(pending.isWaiting(a))
        let r2 = pending.due(at: start.addingTimeInterval(5))
        #expect(r2.map(\.id) == [a])
        #expect(!pending.isWaiting(a))
    }

    @Test func dueDecisionsAreHandedOverOnce() {
        var pending = PendingDecisions()
        pending.decide(a, .confirm, at: start)
        _ = pending.due(at: start.addingTimeInterval(6))
        let r3 = pending.due(at: start.addingTimeInterval(7))
        #expect(r3.isEmpty)
    }

    @Test func undoInsideTheWindowDropsIt() {
        var pending = PendingDecisions()
        pending.decide(a, .fileAsTransfer, at: start)
        let r4 = pending.undo(a)
        #expect(r4)
        let r5 = pending.due(at: start.addingTimeInterval(10))
        #expect(r5.isEmpty)
        let r6 = pending.flush()
        #expect(r6.isEmpty)
    }

    @Test func undoAfterItWasSavedDoesNothing() {
        var pending = PendingDecisions()
        pending.decide(a, .confirm, at: start)
        _ = pending.due(at: start.addingTimeInterval(5))
        let r7 = pending.undo(a)
        #expect(!r7)
    }

    @Test func decidingAgainReplacesTheEarlierDecisionAndRestartsItsTimer() {
        var pending = PendingDecisions()
        pending.decide(a, .fileAsTransfer, at: start)
        pending.decide(a, .notTransfer, at: start.addingTimeInterval(3))
        let r8 = pending.due(at: start.addingTimeInterval(5))
        #expect(r8.isEmpty)
        let saved = pending.due(at: start.addingTimeInterval(8))
        #expect(saved.map(\.decision) == [.notTransfer])
        #expect(saved.count == 1)
    }

    @Test func aBatchKeepsATimerEach() {
        var pending = PendingDecisions()
        pending.decide([a, b], .confirm, at: start)
        pending.decide(c, .confirm, at: start.addingTimeInterval(2))
        let r9 = pending.undo(b)
        #expect(r9)
        let r10 = pending.due(at: start.addingTimeInterval(5))
        #expect(r10.map(\.id) == [a])
        let r11 = pending.due(at: start.addingTimeInterval(7))
        #expect(r11.map(\.id) == [c])
    }

    @Test func leavingSavesWhateverIsStillWaitingInOrder() {
        var pending = PendingDecisions()
        pending.decide(b, .confirm, at: start)
        pending.decide(a, .notTransfer, at: start.addingTimeInterval(1))
        let r12 = pending.flush()
        #expect(r12.map(\.id) == [b, a])
        #expect(pending.waiting.isEmpty)
    }

    @Test func theWaitingListIsOldestFirstWithTimeLeft() {
        var pending = PendingDecisions()
        pending.decide(a, .confirm, at: start)
        pending.decide(b, .confirm, at: start.addingTimeInterval(2))
        #expect(pending.waiting.map(\.id) == [a, b])
        #expect(pending.waiting.first?.savesAt == start.addingTimeInterval(PendingDecisions.window))
    }
}

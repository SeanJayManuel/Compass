import Core
import Foundation
import Testing

@Suite struct AutoSyncTests {
    let zone = TimeZone(identifier: "America/New_York")!
    /// Oct 20 2026, 9:00 in New York.
    let now = Date(timeIntervalSince1970: 1_792_501_200)

    @Test func neverWithoutAConnection() {
        #expect(!AutoSync.shouldSync(attempts: [], connected: false, now: now, timeZone: zone))
    }

    @Test func syncsWhenNothingHasRunYet() {
        #expect(AutoSync.shouldSync(attempts: [], connected: true, now: now, timeZone: zone))
    }

    @Test func atMostOnceADayAfterASuccess() {
        let earlierToday = SyncAttempt(startedAt: now.addingTimeInterval(-2 * 3600), succeeded: true)
        let lastNight = SyncAttempt(startedAt: now.addingTimeInterval(-10 * 3600), succeeded: true)
        #expect(!AutoSync.shouldSync(attempts: [earlierToday], connected: true, now: now, timeZone: zone))
        #expect(AutoSync.shouldSync(attempts: [lastNight], connected: true, now: now, timeZone: zone))
    }

    @Test func aFailureWaitsAnHourBeforeTryingAgain() {
        let recentFailure = SyncAttempt(startedAt: now.addingTimeInterval(-10 * 60), succeeded: false)
        let oldFailure = SyncAttempt(startedAt: now.addingTimeInterval(-2 * 3600), succeeded: false)
        #expect(!AutoSync.shouldSync(attempts: [recentFailure], connected: true, now: now, timeZone: zone))
        #expect(AutoSync.shouldSync(attempts: [oldFailure], connected: true, now: now, timeZone: zone))
    }

    @Test func staysWellUnderTheBridgesDailyLimit() {
        let busyDay = (1...12).map { SyncAttempt(startedAt: now.addingTimeInterval(Double(-$0) * 3600 - 60), succeeded: false) }
        #expect(!AutoSync.shouldSync(attempts: busyDay, connected: true, now: now, timeZone: zone))
    }
}

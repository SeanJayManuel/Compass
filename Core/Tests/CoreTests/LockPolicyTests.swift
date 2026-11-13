import Core
import Foundation
import Testing

@Suite struct LockPolicyTests {
    let launch = Date(timeIntervalSince1970: 1_792_500_000)

    func minutes(_ count: Double) -> Date { launch.addingTimeInterval(count * 60) }

    func unlockedAtLaunch() -> LockPolicy {
        var policy = LockPolicy(launchedAt: launch)
        policy.handle(.unlocked, at: launch)
        return policy
    }

    @Test func theAppStartsLocked() {
        #expect(LockPolicy(launchedAt: launch).isLocked)
    }

    @Test func cancellingOrFailingTouchIDStaysLocked() {
        var policy = LockPolicy(launchedAt: launch)
        policy.handle(.unlockFailed, at: minutes(0.1))
        #expect(policy.isLocked)
    }

    @Test func authenticatingUnlocks() {
        #expect(!unlockedAtLaunch().isLocked)
    }

    @Test(arguments: [LockEvent.systemSlept, .screenLocked])
    func sleepingOrLockingTheMacLocksTheApp(event: LockEvent) {
        var policy = unlockedAtLaunch()
        policy.handle(event, at: minutes(1))
        #expect(policy.isLocked)
    }

    @Test func fifteenMinutesWithoutInputLocks() {
        var policy = unlockedAtLaunch()
        policy.handle(.clockTick, at: minutes(14.9))
        #expect(!policy.isLocked)
        policy.handle(.clockTick, at: minutes(15))
        #expect(policy.isLocked)
    }

    @Test func inputResetsTheIdleTimer() {
        var policy = unlockedAtLaunch()
        policy.handle(.userActivity, at: minutes(10))
        policy.handle(.clockTick, at: minutes(24))
        #expect(!policy.isLocked)
        policy.handle(.clockTick, at: minutes(25))
        #expect(policy.isLocked)
    }

    @Test func idleTimeBeforeUnlockingDoesNotCount() {
        var policy = LockPolicy(launchedAt: launch)
        policy.handle(.unlocked, at: minutes(20))
        policy.handle(.clockTick, at: minutes(21))
        #expect(!policy.isLocked)
    }

    @Test func aShorterTimeoutIsHonoured() {
        var policy = LockPolicy(launchedAt: launch, idleTimeout: 60)
        policy.handle(.unlocked, at: launch)
        policy.handle(.clockTick, at: minutes(1))
        #expect(policy.isLocked)
    }

    @Test func neverLockingWhenIdleStillLocksOnSleep() {
        var policy = LockPolicy(launchedAt: launch, idleTimeout: nil)
        policy.handle(.unlocked, at: launch)
        policy.handle(.clockTick, at: minutes(600))
        #expect(!policy.isLocked)
        policy.handle(.systemSlept, at: minutes(601))
        #expect(policy.isLocked)
    }

    @Test(arguments: [LockEvent.systemSlept, .screenLocked])
    func lockingOnlyAtLaunchIgnoresSleepAndScreenLock(event: LockEvent) {
        var policy = LockPolicy(launchedAt: launch, mode: .onLaunch)
        #expect(policy.isLocked)
        policy.handle(.unlocked, at: launch)
        policy.handle(event, at: minutes(1))
        policy.handle(.clockTick, at: minutes(600))
        #expect(!policy.isLocked)
    }

    @Test func withTheLockOffItStartsUnlockedAndNothingLocksIt() {
        var policy = LockPolicy(launchedAt: launch, mode: .off)
        #expect(!policy.isLocked)
        for event in [LockEvent.systemSlept, .screenLocked, .lockRequested, .unlockFailed] {
            policy.handle(event, at: minutes(1))
        }
        policy.handle(.clockTick, at: minutes(600))
        #expect(!policy.isLocked)
    }

    @Test(arguments: [LockMode.onLaunch, .afterSleepOrIdle])
    func lockNowLocks(mode: LockMode) {
        var policy = LockPolicy(launchedAt: launch, mode: mode)
        policy.handle(.unlocked, at: launch)
        policy.handle(.lockRequested, at: minutes(1))
        #expect(policy.isLocked)
    }

    @Test func closingTheWindowLocksInEitherModeThatLocks() {
        for mode in [LockMode.onLaunch, .afterSleepOrIdle] {
            var policy = LockPolicy(launchedAt: launch, mode: mode)
            policy.handle(.unlocked, at: launch)
            policy.handle(.windowClosed, at: minutes(1))
            #expect(policy.isLocked)
        }
        var off = LockPolicy(launchedAt: launch, mode: .off)
        off.handle(.windowClosed, at: minutes(1))
        #expect(!off.isLocked)
    }
}

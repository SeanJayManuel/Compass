import Core
import Testing

@Suite struct StoreGuardTests {
    let known = StoreShape(["AccountRecord": ["id", "name"], "PlaybookEntryRecord": ["id", "entryData"]])

    @Test func aNewStoreOpens() {
        #expect(StoreGuard.unknown(in: StoreShape([:]), known: known).isEmpty)
    }

    @Test func aStoreFromThisBuildOpens() {
        #expect(StoreGuard.unknown(in: known, known: known).isEmpty)
    }

    /// An older store migrates forward: adding a model or a field loses nothing.
    @Test func anOlderStoreOpens() {
        let older = StoreShape(["AccountRecord": ["id"]])
        #expect(StoreGuard.unknown(in: older, known: known).isEmpty)
    }

    /// What happened on Oct 30, 2026: a build from before the Playbook opened
    /// the store and dropped it. That build must refuse instead.
    @Test func aStoreWithAModelThisBuildDoesntKnowIsRefused() {
        let newer = StoreShape([
            "AccountRecord": ["id", "name"], "PlaybookEntryRecord": ["id", "entryData"],
            "PayProfileRecord": ["profileData"]
        ])
        #expect(StoreGuard.unknown(in: newer, known: known) == ["PayProfileRecord"])
    }

    @Test func aStoreWithAFieldThisBuildDoesntKnowIsRefused() {
        let newer = StoreShape(["AccountRecord": ["id", "name", "note"], "PlaybookEntryRecord": ["id", "entryData"]])
        #expect(StoreGuard.unknown(in: newer, known: known) == ["AccountRecord.note"])
    }

    /// A model or field removed on purpose is listed as retired, so the store
    /// still opens and the migration drops it.
    @Test func aRetiredModelOrFieldOpens() {
        let older = StoreShape(["AccountRecord": ["id", "name", "pinned"], "ResolutionRecord": ["id"]])
        #expect(StoreGuard.unknown(in: older, known: known, retired: ["ResolutionRecord", "AccountRecord.pinned"]).isEmpty)
    }

    /// A store read only from its metadata names its models but not their
    /// fields; the models are still checked.
    @Test func merging() {
        let fromMetadata = StoreShape(["AccountRecord": [], "HabitRecord": []])
        let fromSidecar = StoreShape(["AccountRecord": ["id", "name"]])
        let merged = fromMetadata.merging(fromSidecar)
        #expect(merged == StoreShape(["AccountRecord": ["id", "name"], "HabitRecord": []]))
        #expect(StoreGuard.unknown(in: merged, known: known) == ["HabitRecord"])
    }
}

import XCTest
@testable import GramMusic

/// What the app is allowed to keep on disk, and what it must let go of.
///
/// The rule: **a track you downloaded and a track you merely played are not the same thing.** The
/// first is yours until you delete it; the second is a cache entry living under a byte budget and
/// an age limit. Before this split there was no eviction of audio anywhere — every track ever
/// played stayed forever and was listed as "Downloaded", so listening quietly consumed gigabytes
/// the user could not reclaim short of deleting the app.
@MainActor
final class AudioCacheTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let mb: Int64 = 1024 * 1024

    private func makeLedger(budgetMB: Int64 = 100,
                            maxAge: TimeInterval = AudioCacheLedger.defaultMaxAge) -> AudioCacheLedger {
        AudioCacheLedger(budget: budgetMB * 1024 * 1024, maxAge: maxAge)
    }

    // MARK: - Budget

    func test_underBudget_evictsNothing() {
        let ledger = makeLedger(budgetMB: 100)
        ledger.record("a", bytes: 10 * mb, now: t0)
        ledger.record("b", bytes: 10 * mb, now: t0)
        XCTAssertTrue(ledger.keysToEvict(now: t0).isEmpty)
    }

    func test_overBudget_evictsLeastRecentlyPlayedFirst() {
        let ledger = makeLedger(budgetMB: 70)
        ledger.record("oldest", bytes: 30 * mb, now: t0)
        ledger.record("middle", bytes: 30 * mb, now: t0.addingTimeInterval(60))
        ledger.record("newest", bytes: 30 * mb, now: t0.addingTimeInterval(120))

        XCTAssertEqual(ledger.keysToEvict(now: t0.addingTimeInterval(200)), ["oldest"],
                       "90MB against a 70MB budget: one eviction, and it's the one played longest ago")
    }

    func test_eviction_stopsAsSoonAsItIsUnderBudget() {
        let ledger = makeLedger(budgetMB: 50)
        ledger.record("oldest", bytes: 30 * mb, now: t0)
        ledger.record("middle", bytes: 30 * mb, now: t0.addingTimeInterval(60))
        ledger.record("newest", bytes: 30 * mb, now: t0.addingTimeInterval(120))

        // 90MB against 50MB needs 40MB freed, so one 30MB file is not enough — but two are, and
        // the newest must survive.
        XCTAssertEqual(ledger.keysToEvict(now: t0.addingTimeInterval(200)), ["oldest", "middle"])
    }

    func test_eviction_takesAsManyAsItNeeds() {
        let ledger = makeLedger(budgetMB: 10)
        for (i, key) in ["a", "b", "c"].enumerated() {
            ledger.record(key, bytes: 20 * mb, now: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(ledger.keysToEvict(now: t0.addingTimeInterval(10)), ["a", "b", "c"])
    }

    func test_playingATrackKeepsItAlive() {
        let ledger = makeLedger(budgetMB: 50)
        ledger.record("a", bytes: 30 * mb, now: t0)
        ledger.record("b", bytes: 30 * mb, now: t0.addingTimeInterval(60))

        ledger.touch("a", now: t0.addingTimeInterval(120))   // played again just now
        XCTAssertEqual(ledger.keysToEvict(now: t0.addingTimeInterval(130)), ["b"],
                       "the one actually being listened to must not be the one dropped")
    }

    // MARK: - Age ("remove it after a while")

    func test_staleEntries_expireEvenWithRoomToSpare() {
        let ledger = makeLedger(budgetMB: 10_000, maxAge: 60)
        ledger.record("ancient", bytes: 1 * mb, now: t0)
        ledger.record("fresh", bytes: 1 * mb, now: t0.addingTimeInterval(600))

        XCTAssertEqual(ledger.keysToEvict(now: t0.addingTimeInterval(660)), ["ancient"],
                       "a track played once months ago is dead weight however much room there is")
    }

    func test_expiryAndBudget_composeWithoutDoubleCounting() {
        let ledger = makeLedger(budgetMB: 25, maxAge: 60)
        ledger.record("ancient", bytes: 20 * mb, now: t0)
        ledger.record("old", bytes: 20 * mb, now: t0.addingTimeInterval(600))
        ledger.record("new", bytes: 20 * mb, now: t0.addingTimeInterval(700))

        let victims = ledger.keysToEvict(now: t0.addingTimeInterval(700))
        XCTAssertEqual(victims, ["ancient", "old"])
        XCTAssertEqual(Set(victims).count, victims.count, "no key may be listed twice")
    }

    // `usedBytes` is maintained incrementally (a view body reads it), so every path that adds or
    // removes an entry has to keep it honest — a stale total silently breaks eviction.
    func test_usedBytes_tracksEveryMutation() {
        let ledger = makeLedger()
        XCTAssertEqual(ledger.usedBytes, 0)

        ledger.record("a", bytes: 10 * mb, now: t0)
        ledger.record("b", bytes: 5 * mb, now: t0)
        XCTAssertEqual(ledger.usedBytes, 15 * mb)

        ledger.record("a", bytes: 20 * mb, now: t0)   // the file grew
        XCTAssertEqual(ledger.usedBytes, 25 * mb, "re-recording adjusts by the difference")

        ledger.forget("b")
        XCTAssertEqual(ledger.usedBytes, 20 * mb)

        ledger.promote("a")
        XCTAssertEqual(ledger.usedBytes, 0, "a promoted file stops counting against the budget")

        ledger.removeAll()
        XCTAssertEqual(ledger.usedBytes, 0)
    }

    func test_usedBytes_survivesRestoreAndProtection() {
        let ledger = makeLedger()
        ledger.record("a", bytes: 10 * mb, now: t0)
        ledger.record("b", bytes: 10 * mb, now: t0)
        let snapshot = ledger.snapshot()

        let restored = makeLedger()
        restored.promote("a")            // "a" is an explicit download in this session
        restored.restore(snapshot)
        XCTAssertEqual(restored.usedBytes, 10 * mb, "only the still-cached half counts")
    }

    // MARK: - Protection

    // The whole point of the split: something the user asked to keep is never taken away.
    func test_explicitDownloads_areNeverEvicted() {
        let ledger = makeLedger(budgetMB: 1, maxAge: 1)
        ledger.record("kept", bytes: 500 * mb, now: t0)
        ledger.promote("kept")

        XCTAssertTrue(ledger.keysToEvict(now: t0.addingTimeInterval(10_000)).isEmpty)
        XCTAssertFalse(ledger.contains("kept"), "it left the cache entirely")
        XCTAssertEqual(ledger.usedBytes, 0, "and stopped counting against the budget")
    }

    func test_protectedPlaybackKeys_areNeverEvicted() {
        let ledger = makeLedger(budgetMB: 1)
        ledger.record("playing", bytes: 100 * mb, now: t0)
        ledger.record("other", bytes: 100 * mb, now: t0.addingTimeInterval(60))
        ledger.setProtected(["playing"])

        XCTAssertFalse(ledger.keysToEvict(now: t0.addingTimeInterval(100)).contains("playing"),
                       "evicting the file of the track currently playing would be a spectacular own goal")
    }

    // Protection means "don't delete this yet", **not** "forget it exists". Dropping the record
    // left the file on disk with nothing tracking it the moment playback moved on — untracked, and
    // so never evictable again.
    func test_protectionKeepsTheRecord_soTheFileIsStillTrackedAfterwards() {
        let ledger = makeLedger(budgetMB: 1)
        ledger.record("playing", bytes: 100 * mb, now: t0)
        ledger.setProtected(["playing"])
        XCTAssertTrue(ledger.contains("playing"), "still a cache entry, just not an evictable one")

        ledger.setProtected([])   // playback moved on
        XCTAssertEqual(ledger.keysToEvict(now: t0.addingTimeInterval(100)), ["playing"],
                       "and now it can be reclaimed like anything else")
    }

    // A track that is merely *protected* is still cache, so recording it must work. Barring it
    // meant a played track's file was never accounted for at all.
    func test_recordingAProtectedKey_stillTracksIt() {
        let ledger = makeLedger()
        ledger.setProtected(["playing"])
        ledger.record("playing", bytes: 7 * mb, now: t0)

        XCTAssertTrue(ledger.contains("playing"))
        XCTAssertEqual(ledger.usedBytes, 7 * mb)
    }

    func test_recordingAnExplicitDownload_doesNotMakeItACacheEntry() {
        let ledger = makeLedger()
        ledger.promote("mine")
        ledger.record("mine", bytes: 50 * mb, now: t0)
        XCTAssertFalse(ledger.contains("mine"))
        XCTAssertEqual(ledger.usedBytes, 0)
    }

    // Un-downloading with the file kept: it stops being a download and becomes ordinary cache.
    func test_demoteThenRecord_turnsADownloadBackIntoCache() {
        let ledger = makeLedger()
        ledger.promote("x")
        ledger.demote("x")
        ledger.record("x", bytes: 3 * mb, remoteFileId: "r-x", now: t0)

        XCTAssertTrue(ledger.contains("x"))
        XCTAssertEqual(ledger.usedBytes, 3 * mb)
        XCTAssertEqual(ledger.entry("x")?.remoteFileId, "r-x", "still deletable later")
    }

    func test_removingADownload_leavesNoCacheEntryBehind() {
        let ledger = makeLedger()
        ledger.promote("gone")
        ledger.demote("gone")
        XCTAssertFalse(ledger.contains("gone"), "the file is deleted, so it isn't cache either")
        XCTAssertFalse(ledger.protectedKeys.contains("gone"))
    }

    func test_clearCache_keepsExplicitDownloads() {
        let ledger = makeLedger()
        ledger.record("cached", bytes: 1 * mb, now: t0)
        ledger.promote("kept")

        XCTAssertEqual(ledger.allEvictableKeys(), ["cached"])
    }

    // An entry has to carry enough to *delete* its file. Without the remote file id an eviction
    // could only delete files whose track happened to still be in memory; every other entry was
    // dropped from the ledger while its bytes stayed on disk — a leak inside the mechanism whose
    // whole job is to prevent one.
    func test_entriesRememberHowToDeleteTheirFile() {
        let ledger = makeLedger()
        ledger.record("a", bytes: 1 * mb, remoteFileId: "remote-a", now: t0)
        XCTAssertEqual(ledger.entry("a")?.remoteFileId, "remote-a")
    }

    func test_reRecording_doesNotLoseTheRemoteFileId() {
        let ledger = makeLedger()
        ledger.record("a", bytes: 1 * mb, remoteFileId: "remote-a", now: t0)
        ledger.record("a", bytes: 2 * mb, now: t0.addingTimeInterval(60))   // a later touch, no id
        XCTAssertEqual(ledger.entry("a")?.remoteFileId, "remote-a")
        XCTAssertEqual(ledger.entry("a")?.bytes, 2 * mb)
    }

    // MARK: - Persistence

    // Without this the budget resets to zero on every cold start and nothing is ever evicted —
    // which is the bug the ledger exists to fix, reintroduced.
    func test_ledgerSurvivesRelaunch() {
        let ledger = makeLedger(budgetMB: 50)
        ledger.record("a", bytes: 30 * mb, now: t0)
        ledger.record("b", bytes: 30 * mb, now: t0.addingTimeInterval(60))
        let snapshot = ledger.snapshot()

        let restored = makeLedger(budgetMB: 50)
        restored.restore(snapshot)

        XCTAssertEqual(restored.usedBytes, 60 * mb)
        XCTAssertEqual(restored.keysToEvict(now: t0.addingTimeInterval(100)), ["a"],
                       "LRU order has to survive too, or eviction picks at random")
    }

    func test_restore_doesNotResurrectAProtectedKeyAsCache() {
        let ledger = makeLedger()
        ledger.record("x", bytes: 1 * mb, now: t0)
        let snapshot = ledger.snapshot()

        let restored = makeLedger()
        restored.promote("x")          // it is an explicit download in this session
        restored.restore(snapshot)
        XCTAssertFalse(restored.contains("x"))
    }

    func test_snapshotIsCodable() throws {
        let ledger = makeLedger()
        ledger.record("a", bytes: 5 * mb, now: t0)
        let data = try JSONEncoder().encode(ledger.snapshot())
        let decoded = try JSONDecoder().decode([CachedAudioFile].self, from: data)
        XCTAssertEqual(decoded.first?.key, "a")
        XCTAssertEqual(decoded.first?.bytes, 5 * mb)
    }
}

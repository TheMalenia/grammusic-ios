import XCTest
@testable import GramMusic

/// The two promises the download pipeline makes, pinned as tests.
///
/// 1. **What the user is listening to downloads first.** Then the next track, then the rest of
///    the queue, and only then bulk work they asked for in the background. The first two also get
///    a reserved lane, so a "Download all" on a long playlist can never delay the song playing.
/// 2. **No error stops downloading.** A failure is one track's problem: it is requeued with
///    backoff (playback-critical work without an attempt ceiling) or dropped alone, and either
///    way the queue keeps handing out the next track.
///
/// `DownloadScheduler` is pure and takes `now` on every entry point, so all of this is verified
/// with no backend, no tasks and no waiting in real time.
@MainActor
final class DownloadSchedulerTests: XCTestCase {

    private func track(_ id: String) -> AudioTrack {
        AudioTrack(chatId: 0, messageId: 0, fileId: 1, remoteUniqueId: id, remoteFileId: "r-\(id)",
                   title: "Song \(id)", performer: "Artist", duration: 100, fileName: "\(id).mp3")
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeScheduler(concurrent: Int = 3, lane: Int = 2) -> DownloadScheduler {
        DownloadScheduler(maxConcurrent: concurrent, maxPlaybackLane: lane)
    }

    /// Drain everything admissible right now, newest-first order of admission.
    private func drain(_ s: DownloadScheduler, now: Date) -> [String] {
        var out: [String] = []
        while let entry = s.startNext(now: now) { out.append(entry.key) }
        return out
    }

    // MARK: - Ordering: playback first, always

    func test_order_isPlayingThenNextThenUpcomingThenBulk() {
        let s = makeScheduler(concurrent: 10)
        // Submitted in deliberately the wrong order.
        s.submit(track("bulk"), priority: .explicit, now: t0)
        s.submit(track("upcoming"), priority: .upcoming, now: t0)
        s.submit(track("next"), priority: .next, now: t0)
        s.submit(track("playing"), priority: .current, now: t0)

        XCTAssertEqual(drain(s, now: t0), ["playing", "next", "upcoming", "bulk"])
    }

    func test_equalPriority_keepsSubmissionOrder() {
        let s = makeScheduler(concurrent: 10)
        for id in ["a", "b", "c"] { s.submit(track(id), priority: .explicit, now: t0) }
        XCTAssertEqual(drain(s, now: t0), ["a", "b", "c"])
    }

    // The bug the reserved lane exists to prevent: a "Download all" fills every shared slot and
    // the song the user is actually listening to sits behind it waiting to buffer.
    func test_saturatedPool_stillAdmitsThePlayingTrackAndTheNextOne() {
        let s = makeScheduler(concurrent: 3, lane: 2)
        for id in ["b1", "b2", "b3", "b4"] { s.submit(track(id), priority: .explicit, now: t0) }
        XCTAssertEqual(drain(s, now: t0), ["b1", "b2", "b3"], "the shared pool fills up")
        XCTAssertNil(s.nextAdmissible(now: t0), "and then blocks further bulk work")

        s.submit(track("playing"), priority: .current, now: t0)
        s.submit(track("next"), priority: .next, now: t0)
        XCTAssertEqual(drain(s, now: t0), ["playing", "next"],
                       "playback jumps the saturated pool via its reserved lane")
    }

    func test_playbackLane_isItselfBounded() {
        let s = makeScheduler(concurrent: 1, lane: 1)
        s.submit(track("playing"), priority: .current, now: t0)
        s.submit(track("next"), priority: .next, now: t0)
        s.submit(track("third"), priority: .next, now: t0)

        // `playing` takes the one lane slot, `next` spills into the one shared slot, and then
        // there is genuinely nothing left — "reserved" is not "infinite".
        XCTAssertEqual(drain(s, now: t0), ["playing", "next"])
        XCTAssertNil(s.nextAdmissible(now: t0), "the lane is reserved, not infinite")
    }

    /// The lane is *additional* capacity, not a share of the pool: playback takes a lane slot in
    /// preference to a shared one, so it never competes with bulk work for the same slot.
    func test_playbackTakesTheLaneBeforeTheSharedPool() {
        let s = makeScheduler(concurrent: 3, lane: 2)
        s.submit(track("playing"), priority: .current, now: t0)
        _ = s.startNext(now: t0)

        XCTAssertEqual(s.activePlaybackCount, 1)
        XCTAssertEqual(s.sharedCount, 0, "the shared pool stays fully available to bulk work")
    }

    func test_bulkWork_neverUsesThePlaybackLane() {
        let s = makeScheduler(concurrent: 1, lane: 2)
        s.submit(track("bulk1"), priority: .explicit, now: t0)
        s.submit(track("bulk2"), priority: .explicit, now: t0)
        _ = s.startNext(now: t0)

        XCTAssertNil(s.nextAdmissible(now: t0),
                     "the shared pool is full; bulk may not spill into the reserved lane")
        XCTAssertEqual(s.activePlaybackCount, 0)
    }

    // MARK: - Re-aiming as the queue moves

    func test_submit_raisesPriorityButNeverLowersIt() {
        let s = makeScheduler(concurrent: 10)
        s.submit(track("x"), priority: .explicit, now: t0)
        s.submit(track("x"), priority: .current, now: t0)
        XCTAssertEqual(s.entry("x")?.priority, .current, "becoming the playing track promotes it")

        s.submit(track("x"), priority: .upcoming, now: t0)
        XCTAssertEqual(s.entry("x")?.priority, .current,
                       "a lower-priority submission must not demote work playback needs")
    }

    func test_promotionIntoPlayback_clearsABulkBackoff() {
        let s = makeScheduler()
        s.submit(track("x"), priority: .explicit, now: t0)
        _ = s.startNext(now: t0)
        guard case .retryScheduled = s.didFail("x", error: TelegramError.transient("dropped"), now: t0) else {
            return XCTFail("a transient failure must be requeued")
        }
        XCTAssertNil(s.nextAdmissible(now: t0), "it is backing off")

        // The user skipped onto it — they are waiting on this file now.
        s.submit(track("x"), priority: .current, now: t0)
        XCTAssertEqual(s.nextAdmissible(now: t0)?.key, "x",
                       "the song being listened to must not sit out a bulk backoff")
    }

    // A live transfer can't change lanes, but its *record* must still be promoted — that record is
    // what a bulk "Stop" consults before cancelling, and what a failure is retried under. Missing
    // this let the chat screen's Stop button cancel the download of the track that was playing.
    func test_promotingAnInFlightDownload_updatesItsRecord() {
        let s = makeScheduler()
        s.submit(track("x"), priority: .explicit, now: t0)
        _ = s.startNext(now: t0)
        XCTAssertEqual(s.entry("x")?.priority, .explicit)

        s.submit(track("x"), priority: .current, now: t0)
        XCTAssertEqual(s.entry("x")?.priority, .current,
                       "it is the playing track now, whatever it started life as")
    }

    func test_anInFlightPlaybackDownload_isDroppedWhenItLeavesThePlan() {
        let s = makeScheduler()
        s.setPlaybackPlan([track("a")], now: t0)
        _ = s.startNext(now: t0)

        XCTAssertEqual(s.setPlaybackPlan([track("b")], now: t0), ["a"],
                       "the user skipped past it while it was downloading")
    }

    func test_anInFlightBulkDownload_isNeverDroppedByThePlayQueue() {
        let s = makeScheduler()
        s.submit(track("bulk"), priority: .explicit, now: t0)
        _ = s.startNext(now: t0)

        XCTAssertTrue(s.setPlaybackPlan([track("a"), track("b")], now: t0).isEmpty,
                      "the play queue moving on must not cancel a download the user asked for")
        XCTAssertTrue(s.isQueued("bulk"))
    }

    func test_playbackPlan_dropsWhatFellOutOfItButKeepsExplicitWork() {
        let s = makeScheduler(concurrent: 10)
        s.submit(track("keepMe"), priority: .explicit, now: t0)
        s.setPlaybackPlan([track("a"), track("b"), track("c")], now: t0)

        let dropped = s.setPlaybackPlan([track("b"), track("c")], now: t0)
        XCTAssertEqual(dropped, ["a"], "the track the user skipped past stops being chased")
        XCTAssertFalse(s.isQueued("a"))
        XCTAssertTrue(s.isQueued("keepMe"), "a download the user asked for survives the queue moving")
        XCTAssertEqual(s.entry("b")?.priority, .current)
        XCTAssertEqual(s.entry("c")?.priority, .next)
    }

    func test_playbackPlan_assignsCurrentNextThenUpcoming() {
        let s = makeScheduler(concurrent: 10)
        s.setPlaybackPlan([track("p"), track("n"), track("u1"), track("u2")], now: t0)
        XCTAssertEqual(s.entry("p")?.priority, .current)
        XCTAssertEqual(s.entry("n")?.priority, .next)
        XCTAssertEqual(s.entry("u1")?.priority, .upcoming)
        XCTAssertEqual(s.entry("u2")?.priority, .upcoming)
        XCTAssertEqual(drain(s, now: t0), ["p", "n", "u1", "u2"], "and they start in that order")
    }

    // MARK: - No error stops downloading

    func test_aFailureNeverBlocksTheRestOfTheQueue() {
        let s = makeScheduler(concurrent: 1)
        s.submit(track("bad"), priority: .explicit, now: t0)
        s.submit(track("good"), priority: .explicit, now: t0)

        XCTAssertEqual(s.startNext(now: t0)?.key, "bad")
        _ = s.didFail("bad", error: TelegramError.backend("server said no"), now: t0)

        XCTAssertEqual(s.startNext(now: t0)?.key, "good",
                       "one track failing must free its slot for the next one immediately")
    }

    func test_transientFailure_isRequeuedWithBackoffAndComesBack() {
        let s = makeScheduler()
        s.submit(track("x"), priority: .explicit, now: t0)
        _ = s.startNext(now: t0)

        guard case .retryScheduled(let at) = s.didFail("x", error: TelegramError.transient("link dropped"), now: t0) else {
            return XCTFail("a dropped link is not a real failure yet")
        }
        XCTAssertGreaterThan(at, t0)
        XCTAssertNil(s.nextAdmissible(now: t0), "not before its backoff elapses")
        XCTAssertEqual(s.nextAdmissible(now: at)?.key, "x", "and it is back the moment it does")
    }

    func test_backoffEscalatesAcrossAttempts() {
        let s = makeScheduler()
        s.submit(track("x"), priority: .explicit, now: t0)

        var delays: [TimeInterval] = []
        var now = t0
        for _ in 0..<3 {
            _ = s.startNext(now: now)
            guard case .retryScheduled(let at) = s.didFail("x", error: TelegramError.transient("down"), now: now) else {
                return XCTFail("still retryable")
            }
            delays.append(at.timeIntervalSince(now))
            now = at
        }
        XCTAssertEqual(delays, delays.sorted(), "each attempt waits at least as long as the last")
        XCTAssertGreaterThan(delays.last!, delays.first!, "the backoff actually escalates")
    }

    // The user's rule, literally: anything we can't classify still gets another go. Only a failure
    // that can never succeed is allowed to cost a track.
    func test_anUnrecognisedError_isStillRetried() {
        struct Mystery: Error {}
        let s = makeScheduler()
        s.submit(track("x"), priority: .explicit, now: t0)
        _ = s.startNext(now: t0)
        guard case .retryScheduled = s.didFail("x", error: Mystery(), now: t0) else {
            return XCTFail("an unknown error is not proof the file is unobtainable")
        }
    }

    func test_permanentFailures_areDroppedAloneAndNotRetried() {
        for error: TelegramError in [.deleted("Song"), .unsupportedFormat("Opus"), .missingCredentials] {
            let s = makeScheduler(concurrent: 2)
            s.submit(track("dead"), priority: .explicit, now: t0)
            s.submit(track("fine"), priority: .explicit, now: t0)
            _ = s.startNext(now: t0)

            XCTAssertEqual(s.didFail("dead", error: error, now: t0), .givenUp,
                           "\(error) can never succeed — retrying only burns the link")
            XCTAssertFalse(s.isQueued("dead"))
            XCTAssertTrue(s.isQueued("fine"), "and the rest of the queue is untouched")
        }
    }

    func test_cancellation_isADecisionNotAFailure() {
        let s = makeScheduler()
        s.submit(track("x"), priority: .explicit, now: t0)
        _ = s.startNext(now: t0)
        XCTAssertEqual(s.didFail("x", error: CancellationError(), now: t0), .givenUp)
        XCTAssertFalse(s.isQueued("x"))
    }

    func test_bulkWork_givesUpEventually() {
        let s = makeScheduler()
        s.submit(track("x"), priority: .explicit, now: t0)
        var now = t0
        var outcomes: [DownloadFailureOutcome] = []
        for _ in 0..<DownloadPriority.explicit.maxAttempts {
            guard s.startNext(now: now) != nil else { break }
            let outcome = s.didFail("x", error: TelegramError.transient("down"), now: now)
            outcomes.append(outcome)
            if case .retryScheduled(let at) = outcome { now = at } else { break }
        }
        XCTAssertEqual(outcomes.last, .givenUp, "a background download stops chasing a dead link")
        XCTAssertFalse(s.isQueued("x"))
    }

    // Giving up on the song the user is listening to is the one failure mode we refuse to have.
    func test_playbackWork_neverGivesUp() {
        let s = makeScheduler()
        s.submit(track("playing"), priority: .current, now: t0)
        var now = t0
        for attempt in 0..<50 {
            guard s.startNext(now: now) != nil else {
                return XCTFail("the playing track stopped being admissible after \(attempt) failures")
            }
            guard case .retryScheduled(let at) = s.didFail("playing", error: TelegramError.transient("down"), now: now) else {
                return XCTFail("gave up on the playing track after \(attempt) failures")
            }
            now = at
        }
        XCTAssertTrue(s.isQueued("playing"))
    }

    func test_attemptHistorySurvivesRestarts() {
        let s = makeScheduler()
        s.submit(track("x"), priority: .explicit, now: t0)
        _ = s.startNext(now: t0)
        _ = s.didFail("x", error: TelegramError.transient("1"), now: t0)
        XCTAssertEqual(s.entry("x")?.attempts, 1)

        let readyAt = s.entry("x")!.readyAt
        _ = s.startNext(now: readyAt)
        _ = s.didFail("x", error: TelegramError.transient("2"), now: readyAt)
        XCTAssertEqual(s.entry("x")?.attempts, 2,
                       "restarting a download must not reset its backoff to zero forever")
    }

    // MARK: - Recovery

    func test_revive_clearsEveryBackoffWhenTheLinkReturns() {
        let s = makeScheduler()
        s.submit(track("x"), priority: .explicit, now: t0)
        _ = s.startNext(now: t0)
        _ = s.didFail("x", error: TelegramError.transient("offline"), now: t0)
        XCTAssertNil(s.nextAdmissible(now: t0))

        s.revive(now: t0)
        XCTAssertEqual(s.nextAdmissible(now: t0)?.key, "x")
        XCTAssertEqual(s.entry("x")?.attempts, 0, "back online is a fresh start, not attempt 4")
    }

    func test_nextWakeUp_isTheEarliestBackoff() {
        let s = makeScheduler(concurrent: 2)
        s.submit(track("a"), priority: .current, now: t0)   // short playback backoff
        s.submit(track("b"), priority: .explicit, now: t0)  // long bulk backoff
        _ = s.startNext(now: t0); _ = s.startNext(now: t0)
        _ = s.didFail("a", error: TelegramError.transient("x"), now: t0)
        _ = s.didFail("b", error: TelegramError.transient("x"), now: t0)

        XCTAssertEqual(s.nextWakeUp(now: t0), s.entry("a")?.readyAt,
                       "the pump wakes for whichever comes back first")
    }

    func test_nextWakeUp_isNilWhenNothingIsWaitingOnAClock() {
        let s = makeScheduler()
        s.submit(track("a"), priority: .current, now: t0)
        XCTAssertNil(s.nextWakeUp(now: t0))
    }

    func test_finishing_freesBothLanes() {
        let s = makeScheduler(concurrent: 1, lane: 1)
        s.submit(track("a"), priority: .current, now: t0)
        _ = s.startNext(now: t0)
        XCTAssertEqual(s.activeCount, 1)
        XCTAssertEqual(s.activePlaybackCount, 1)

        s.didFinish("a")
        XCTAssertEqual(s.activeCount, 0)
        XCTAssertEqual(s.sharedCount, 0)
        XCTAssertEqual(s.activePlaybackCount, 0)
        XCTAssertFalse(s.isQueued("a"))
    }
}

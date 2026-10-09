import XCTest
import AVFoundation
@testable import GramMusic

/// What the player does when the *network* fails underneath it, as opposed to the track being bad.
///
/// These drive `PlayerEngine` through its injected `itemProvider` — the same seam the app wires to
/// Telegram — so a flaky link is expressible as "the provider throws twice, then works". No audio
/// is produced: the assertions are about which errors reach the user and how many attempts the
/// engine made, which is exactly the behaviour that regressed before.
@MainActor
final class PlaybackResilienceTests: XCTestCase {

    private func track(_ id: String) -> AudioTrack {
        AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: id,
                   title: "Song \(id)", performer: "Artist", duration: 100)
    }

    /// A silent, valid item, so a "successful" load is indistinguishable from the real thing as far
    /// as the engine's own bookkeeping is concerned.
    private func silentItem() -> AVPlayerItem {
        AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
    }

    /// Poll until `condition` holds — `play(tracks:)` hands the load to a detached task, and the
    /// retry backoff means the outcome lands a few hundred milliseconds later.
    private func wait(upTo seconds: Double = 6,
                      for condition: @MainActor () -> Bool,
                      _ message: String,
                      file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail(message, file: file, line: line)
    }

    // MARK: - A superseded load must leave no trace

    // The bug: play a track that isn't downloaded yet (slow load), tap a different track, and the
    // *first* track's load eventually completes, installs its item, and its
    // `isPlaybackLikelyToKeepUp` observer finds `isPlaying == true` and starts it. Audio from
    // track A while the UI shows track B.
    func test_slowLoad_supersededByAnotherTrack_neverStartsPlaying() async {
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { [self] t in
                if t.remoteUniqueId == "slow" {
                    try await Task.sleep(for: .milliseconds(600))   // still "downloading"
                }
                return silentItem()
            }
        )
        engine.play(tracks: [track("slow")], startAt: 0)
        try? await Task.sleep(for: .milliseconds(100))   // the slow load is in flight

        engine.play(tracks: [track("fast")], startAt: 0)
        await wait(for: { engine.current?.remoteUniqueId == "fast" }, "the second track never loaded")

        // Well past the slow load's completion: it must not have taken the player back.
        try? await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(engine.current?.remoteUniqueId, "fast",
                       "the abandoned track came back and took over playback")
        XCTAssertEqual(engine.queue.count, 1)
        XCTAssertEqual(engine.queue.first?.remoteUniqueId, "fast")
    }

    // Same race through the queue rather than a new context.
    func test_slowLoad_supersededByASkip_doesNotResurface() async {
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { [self] t in
                if t.remoteUniqueId == "a" { try await Task.sleep(for: .milliseconds(600)) }
                return silentItem()
            }
        )
        engine.play(tracks: [track("a"), track("b")], startAt: 0)
        try? await Task.sleep(for: .milliseconds(100))
        engine.jump(to: 1)
        await wait(for: { engine.current?.remoteUniqueId == "b" }, "the jump never landed")

        try? await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(engine.current?.remoteUniqueId, "b",
                       "the track we skipped away from resumed once its download finished")
    }

    // MARK: - An error must never end the listening session

    // A track that cannot be loaded at all — the link is up, this one file is just broken — must
    // not end playback. Auto-advance hops over it and keeps going; going silent mid-queue is
    // indistinguishable from the app crashing as far as the user is concerned.
    func test_autoAdvance_hopsOverAnyFailingTrackAndKeepsPlaying() async {
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { [self] t in
                if t.remoteUniqueId == "broken" { throw TelegramError.backend("this file is rotten") }
                return silentItem()
            }
        )
        engine.play(tracks: [track("a"), track("broken"), track("c")], startAt: 0)
        await wait(for: { engine.current?.remoteUniqueId == "a" }, "never started")

        engine.next()
        await wait(for: { engine.current?.remoteUniqueId == "c" },
                   "a broken track in the middle of the queue stopped playback instead of being skipped")
        XCTAssertNil(engine.lastError,
                     "once the next track plays there is nothing left to warn about — the failure was handled")
    }

    // The other half of the same rule: it must terminate. A queue where *nothing* loads has to
    // stop, not spin through itself forever.
    func test_aQueueWhereNothingLoads_stopsInsteadOfLooping() async {
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { _ in throw TelegramError.backend("everything is broken") }
        )
        engine.play(tracks: [track("a"), track("b"), track("c")], startAt: 0)
        await wait(for: { engine.lastError != nil && !engine.isPlaying },
                   "an entirely unplayable queue must give up rather than skip forever")
    }

    // An explicit pick is different: the user asked for *that* track, so tell them it failed
    // rather than quietly playing something else.
    func test_explicitPick_reportsInsteadOfSilentlyMovingOn() async {
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { _ in throw TelegramError.unsupportedFormat("Opus") }
        )
        engine.play(tracks: [track("a"), track("b")], startAt: 0)
        await wait(for: { engine.lastError != nil }, "no notice reached the user")
        XCTAssertEqual(engine.current?.remoteUniqueId, "a", "an explicit pick stays where it was put")
    }

    // The point of the whole exercise: a request lost to a bad link must not become red text.
    func test_transientLoadFailure_isRetriedAndNeverSurfaced() async {
        var calls = 0
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { [self] _ in
                calls += 1
                if calls < 3 { throw TelegramError.transient("Connection lost.") }
                return silentItem()
            }
        )

        engine.play(tracks: [track("a")], context: "Test")
        await wait(for: { calls >= 3 }, "the engine should have retried the dropped load")

        XCTAssertNil(engine.lastError, "a link that recovered must leave no error behind")
        XCTAssertEqual(calls, 3)
    }

    func test_progressiveShuffleKeepsCurrentAndAddsOnlyNewTracks() async throws {
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { [self] _ in silentItem() }
        )
        defer { engine.stop() }
        let first = AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: "first",
                               title: "First", performer: "Artist", duration: 100)
        let second = AudioTrack(chatId: 1, messageId: 2, fileId: 2, remoteUniqueId: "second",
                                title: "Second", performer: "Artist", duration: 100)
        let existingTail = AudioTrack(chatId: 1, messageId: 3, fileId: 3, remoteUniqueId: "tail",
                                      title: "Tail", performer: "Artist", duration: 100)
        let third = AudioTrack(chatId: 1, messageId: 4, fileId: 4, remoteUniqueId: "third",
                               title: "Third", performer: "Artist", duration: 100)
        let manual = AudioTrack(chatId: 1, messageId: 5, fileId: 5, remoteUniqueId: "manual",
                                title: "Manual", performer: "Artist", duration: 100)

        let expansionID = try XCTUnwrap(engine.shufflePlayProgressively(
            tracks: [first, second, existingTail], context: "Chat") { _ in
                try? await Task.sleep(for: .seconds(30))
            })
        XCTAssertEqual(engine.queue.count, 3, "loaded tracks must start before expansion")
        engine.jump(to: 1)
        engine.addToQueue(manual)
        let currentIndex = engine.currentIndex
        let stablePrefix = Array(engine.entries.prefix(currentIndex + 1)).map(\.id)
        let explicitQueue = engine.upcomingUserQueueIndices.map { engine.entries[$0].id }
        let contextTailStart = currentIndex + 1 + explicitQueue.count
        let existingContextTail = Set(engine.entries.dropFirst(contextTailStart).map { $0.track.id })
        let currentID = engine.current?.id
        let added = engine.appendToProgressiveShuffle(
            [first, second, existingTail, existingTail, manual, third], sessionID: expansionID)

        XCTAssertEqual(added, 1)
        XCTAssertEqual(engine.current?.id, currentID, "background additions must not move playback")
        XCTAssertEqual(Array(engine.entries.prefix(currentIndex + 1)).map(\.id), stablePrefix,
                       "played/current slots must keep their positions")
        XCTAssertEqual(engine.upcomingUserQueueIndices.map { engine.entries[$0].id }, explicitQueue,
                       "Play Next entries must stay ahead of fetched context tracks")
        XCTAssertEqual(engine.entries[currentIndex + 1].origin, .userQueue)
        XCTAssertEqual(engine.queue.count, 5)
        XCTAssertEqual(Set(engine.queue.map(\.id)).count, 5)
        XCTAssertEqual(Set(engine.entries.dropFirst(contextTailStart).map { $0.track.id }),
                       existingContextTail.union([third.id]))
    }

    func test_queueReplacementCancelsProgressiveShuffleAndRejectsLatePage() async {
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { [self] _ in silentItem() }
        )
        let first = AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: "first",
                               title: "First", performer: "Artist", duration: 100)
        let late = AudioTrack(chatId: 1, messageId: 2, fileId: 2, remoteUniqueId: "late",
                              title: "Late", performer: "Artist", duration: 100)
        var expansionWasCancelled = false
        var sessionID: UUID?
        engine.shufflePlayProgressively(tracks: [first], context: "Chat") { id in
            sessionID = id
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                expansionWasCancelled = true
                _ = engine.appendToProgressiveShuffle([late], sessionID: id)
            }
        }
        while sessionID == nil { await Task.yield() }

        let replacement = AudioTrack(chatId: 2, messageId: 1, fileId: 3, remoteUniqueId: "replacement",
                                    title: "Replacement", performer: "Artist", duration: 100)
        engine.play(tracks: [replacement])
        await wait(for: { expansionWasCancelled }, "queue replacement did not cancel the expansion")
        XCTAssertEqual(engine.queue.map(\.id), [replacement.id])
    }

    func test_turningShuffleOffCancelsProgressiveExpansion() async {
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { [self] _ in silentItem() }
        )
        let initial = AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: "initial",
                                 title: "Initial", performer: "Artist", duration: 100)
        let late = AudioTrack(chatId: 1, messageId: 2, fileId: 2, remoteUniqueId: "late",
                              title: "Late", performer: "Artist", duration: 100)
        var expansionWasCancelled = false
        var latePageWasRejected = false
        engine.shufflePlayProgressively(tracks: [initial], context: "Chat") { id in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                expansionWasCancelled = true
                latePageWasRejected = engine.appendToProgressiveShuffle([late], sessionID: id) == 0
            }
        }

        engine.isShuffle = false
        await wait(for: { expansionWasCancelled }, "shuffle-off did not cancel the expansion")
        XCTAssertTrue(latePageWasRejected)
        XCTAssertEqual(engine.queue.map(\.id), [initial.id])
    }

    func test_stopCancelsProgressiveExpansionAndRejectsLatePage() async {
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { [self] _ in silentItem() }
        )
        let initial = AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: "initial",
                                 title: "Initial", performer: "Artist", duration: 100)
        let late = AudioTrack(chatId: 1, messageId: 2, fileId: 2, remoteUniqueId: "late",
                              title: "Late", performer: "Artist", duration: 100)
        var expansionWasCancelled = false
        var latePageWasRejected = false
        engine.shufflePlayProgressively(tracks: [initial], context: "Chat") { id in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                expansionWasCancelled = true
                latePageWasRejected = engine.appendToProgressiveShuffle([late], sessionID: id) == 0
            }
        }

        engine.stop()
        await wait(for: { expansionWasCancelled }, "stop did not cancel the expansion")
        XCTAssertTrue(latePageWasRejected)
        XCTAssertTrue(engine.queue.isEmpty)
    }

    // The other half of the deal: a problem with the *track* is reported at once, not after
    // three pointless round trips.
    func test_unsupportedFormat_isReportedImmediately_withoutRetrying() async {
        var calls = 0
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { _ in
                calls += 1
                throw TelegramError.unsupportedFormat("Opus")
            }
        )

        engine.play(tracks: [track("a")], context: "Test")
        await wait(for: { engine.lastError != nil }, "an unplayable track should report right away")

        XCTAssertEqual(calls, 1, "retrying a container we cannot decode only wastes the user's time")
        XCTAssertEqual(engine.lastError, "Opus audio isn't supported yet.")
        XCTAssertTrue(engine.lastErrorIsInfo, "an unsupported format is a notice, not an alarm")
    }

    // A link that never comes back still has to end in an explanation rather than silence.
    func test_persistentTransientFailure_eventuallySurfacesTheError() async {
        var calls = 0
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { _ in
                calls += 1
                throw TelegramError.transient("Connection timed out.")
            }
        )

        engine.play(tracks: [track("a")], context: "Test")
        await wait(for: { engine.lastError != nil }, "exhausted retries must still explain themselves")

        XCTAssertEqual(engine.lastError, "Connection timed out.")
        XCTAssertGreaterThan(calls, 1, "it should have tried more than once before giving up")
        XCTAssertFalse(engine.isPlaying)
    }

    // A deleted track is skippable, so auto-advance hops over it — but it must not be *retried*
    // first, or every dead track in a queue costs three round trips.
    func test_deletedTrack_isNotRetried() async {
        var calls = 0
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { _ in
                calls += 1
                throw TelegramError.deleted("Song a")
            }
        )

        engine.play(tracks: [track("a")], context: "Test")
        await wait(for: { engine.lastError != nil }, "a deleted track should report right away")

        XCTAssertEqual(calls, 1)
    }

    // Skipping to another track while a retry is in flight must win: the abandoned load's
    // eventual failure belongs to a track the user already moved on from.
    func test_supersededLoad_doesNotReportOverTheNewTrack() async {
        var callsForA = 0
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { [self] t in
                if t.remoteUniqueId == "a" {
                    callsForA += 1
                    throw TelegramError.transient("Connection lost.")
                }
                return silentItem()
            }
        )

        engine.play(tracks: [track("a")], context: "Test")
        await wait(for: { callsForA >= 1 }, "the first track should have been attempted")
        // Move on while "a" is still backing off.
        engine.play(tracks: [track("b")], context: "Test")

        try? await Task.sleep(for: .seconds(2))
        XCTAssertNil(engine.lastError, "a superseded load must not report over the track now playing")
        XCTAssertEqual(engine.current?.remoteUniqueId, "b")
    }
}

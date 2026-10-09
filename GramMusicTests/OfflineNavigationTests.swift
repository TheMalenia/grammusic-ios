import XCTest
import AVFoundation
@testable import GramMusic

/// Skipping through a queue when only *some* tracks can play — the offline case, where anything
/// not downloaded is unplayable.
///
/// The bug these pin down: `next()` used to increment the index blindly and let `loadCurrent`
/// "fix up" an unplayable landing by searching forward and then **backward**, so offline it found
/// the track it had just skipped away from and playback stuck on one song forever.
@MainActor
final class OfflineNavigationTests: XCTestCase {

    /// `isAutoplayEnabled` persists to UserDefaults, so a test that turns it off would otherwise
    /// leave every later engine — in this suite and others — starting with it off.
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "n_autoplay")
        super.tearDown()
    }


    private func track(_ id: String) -> AudioTrack {
        AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: id,
                   title: "Song \(id)", performer: "Artist", duration: 100)
    }

    /// An engine where `downloaded` names the only tracks that can play — everything else is
    /// "offline and not downloaded".
    private func makeEngine(downloaded: Set<String>) -> PlayerEngine {
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { _ in AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")) }
        )
        engine.isUnavailableOffline = { !downloaded.contains($0.remoteUniqueId) }
        return engine
    }

    private func wait(upTo seconds: Double = 4, for condition: @MainActor () -> Bool,
                      _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(30))
        }
        XCTFail(message, file: file, line: line)
    }

    // MARK: - Next

    // The headline fix: Next skips *over* the undownloaded tracks to the next playable one.
    func test_next_skipsOverUndownloadedTracksToTheNextPlayableOne() async {
        let engine = makeEngine(downloaded: ["a", "d"])
        engine.play(tracks: ["a", "b", "c", "d"].map(track), context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "a" }, "should start on a")

        engine.next()
        await wait(for: { engine.current?.remoteUniqueId == "d" },
                   "next must land on the next downloaded track, not the undownloaded neighbour")
    }

    // The exact reported symptom: nothing playable ahead, so Next must NOT reload the same song.
    func test_next_withNothingPlayableAhead_doesNotReloadTheCurrentTrack() async {
        let engine = makeEngine(downloaded: ["a"])
        engine.isAutoplayEnabled = false   // isolate navigation from the keep-playing behaviour
        engine.play(tracks: ["a", "b", "c"].map(track), context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "a" }, "should start on a")

        engine.next()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(engine.current?.remoteUniqueId, "a")
        XCTAssertEqual(engine.currentIndex, 0, "it must stay put, not bounce back onto itself")
    }

    // ...and the button must not look alive while doing nothing.
    func test_hasNext_isFalseWhenNothingElseCanPlay() async {
        let engine = makeEngine(downloaded: ["a"])
        engine.isAutoplayEnabled = false
        engine.play(tracks: ["a", "b", "c"].map(track), context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "a" }, "should start on a")

        XCTAssertFalse(engine.hasNext)
    }

    func test_hasNext_isTrueWhenAFurtherDownloadedTrackExists() async {
        let engine = makeEngine(downloaded: ["a", "d"])
        engine.play(tracks: ["a", "b", "c", "d"].map(track), context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "a" }, "should start on a")

        XCTAssertTrue(engine.hasNext)
    }

    // Repeat-all should wrap to a playable track, not to whatever happens to be at index 0.
    func test_next_withRepeatAll_wrapsToTheFirstPlayableTrack() async {
        let engine = makeEngine(downloaded: ["b", "d"])
        engine.play(tracks: ["a", "b", "c", "d"].map(track), startAt: 3, context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "d" }, "should start on d")
        engine.repeatMode = .all

        engine.next()
        await wait(for: { engine.current?.remoteUniqueId == "b" },
                   "wrapping must land on a downloaded track, skipping the undownloaded a")
    }

    // MARK: - Previous

    func test_previous_skipsBackOverUndownloadedTracks() async {
        let engine = makeEngine(downloaded: ["a", "d"])
        engine.play(tracks: ["a", "b", "c", "d"].map(track), startAt: 3, context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "d" }, "should start on d")

        engine.previous()
        await wait(for: { engine.current?.remoteUniqueId == "a" },
                   "previous must step back to the nearest downloaded track")
    }

    func test_previous_withNothingPlayableBehind_restartsTheTrackInsteadOfJumpingForward() async {
        let engine = makeEngine(downloaded: ["c"])
        engine.isAutoplayEnabled = false
        engine.play(tracks: ["a", "b", "c"].map(track), startAt: 2, context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "c" }, "should start on c")

        engine.previous()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(engine.current?.remoteUniqueId, "c", "it restarts, it does not jump forward")
        XCTAssertEqual(engine.currentIndex, 2)
    }

    // MARK: - Availability changes

    // Skipped tracks are kept in the queue, so they come back once the network does.
    func test_undownloadedTracksStayInTheQueue() async {
        let engine = makeEngine(downloaded: ["a", "d"])
        engine.play(tracks: ["a", "b", "c", "d"].map(track), context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "a" }, "should start on a")

        engine.next()
        await wait(for: { engine.current?.remoteUniqueId == "d" }, "should have skipped to d")

        XCTAssertEqual(engine.queue.map(\.remoteUniqueId), ["a", "b", "c", "d"],
                       "hopping over a track must not drop it")
    }

    // Back online, everything is playable and Next is a plain step again.
    func test_online_nextIsASimpleStep() async {
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { _ in AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")) }
        )
        engine.play(tracks: ["a", "b", "c"].map(track), context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "a" }, "should start on a")

        engine.next()
        await wait(for: { engine.current?.remoteUniqueId == "b" }, "next should step to b")
    }
}

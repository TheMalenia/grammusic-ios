import XCTest
import AVFoundation
@testable import GramMusic

/// "Keep playing" — what happens when the queue runs out, online and offline.
///
/// Reaching the last track used to just stop. Offline that is especially bleak: a handful of
/// downloaded songs play once and the app goes quiet. These pin the replacement behaviour and,
/// just as importantly, the cases where it must *not* kick in.
@MainActor
final class AutoplayTests: XCTestCase {

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

    private func makeEngine(downloaded: Set<String>? = nil) -> PlayerEngine {
        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { _ in AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")) }
        )
        if let downloaded {
            engine.isUnavailableOffline = { !downloaded.contains($0.remoteUniqueId) }
        }
        engine.isAutoplayEnabled = true   // explicit: the flag is persisted, don't inherit it
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

    // MARK: - Extending

    func test_endOfQueue_continuesIntoProvidedTracks() async {
        let engine = makeEngine()
        engine.autoplayProvider = { [self] _, _ in [track("x"), track("y")] }
        engine.play(tracks: [track("a")], context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "a" }, "should start on a")

        engine.next()   // end of a one-track queue
        await wait(for: { engine.current?.remoteUniqueId == "x" },
                   "autoplay should have appended and moved into the new tracks")
        XCTAssertEqual(engine.queue.map(\.remoteUniqueId), ["a", "x", "y"])
    }

    // The seed lets the provider pick "more like this", and the exclusion list stops it handing
    // back tracks already queued.
    func test_providerReceivesTheFinishedTrackAndTheQueueContents() async {
        let engine = makeEngine()
        var seenSeed: String?
        var seenExclude: Set<String> = []
        engine.autoplayProvider = { [self] seed, exclude in
            seenSeed = seed?.remoteUniqueId
            seenExclude = exclude
            return [track("x")]
        }
        engine.play(tracks: [track("a"), track("b")], startAt: 1, context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "b" }, "should start on b")

        engine.next()
        await wait(for: { engine.current?.remoteUniqueId == "x" }, "should continue into x")

        XCTAssertEqual(seenSeed, "b")
        XCTAssertEqual(seenExclude, ["a", "b"])
    }

    // Offline, the provider is expected to return only downloaded tracks — if it returns something
    // unplayable anyway, we must not strand playback on it.
    func test_unplayableExtension_doesNotStrandPlayback() async {
        let engine = makeEngine(downloaded: ["a"])
        engine.autoplayProvider = { [self] _, _ in [track("unplayable")] }
        engine.play(tracks: [track("a")], context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "a" }, "should start on a")

        engine.next()
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(engine.current?.remoteUniqueId, "a",
                       "an extension we can't play must not become the current track")
    }

    // The queue must not grow forever when a provider always has more to offer.
    func test_extensionsAreBounded() async {
        let engine = makeEngine()
        var calls = 0
        engine.autoplayProvider = { [self] _, _ in
            calls += 1
            return [track("x\(calls)")]
        }
        engine.play(tracks: [track("a")], context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "a" }, "should start on a")

        for _ in 0..<8 {
            engine.next()
            try? await Task.sleep(for: .milliseconds(60))
        }
        XCTAssertLessThanOrEqual(calls, 3, "autoplay must stop extending after its budget")
        XCTAssertFalse(engine.hasNext, "with the budget spent and nothing ahead, Next is dead")
    }

    // A deliberate new play is a fresh start, budget included.
    func test_newPlaySessionRefreshesTheBudget() async {
        let engine = makeEngine()
        var calls = 0
        engine.autoplayProvider = { [self] _, _ in calls += 1; return [track("x\(calls)")] }
        engine.play(tracks: [track("a")], context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "a" }, "should start on a")
        for _ in 0..<5 { engine.next(); try? await Task.sleep(for: .milliseconds(60)) }
        let afterFirstSession = calls

        engine.play(tracks: [track("z")], context: "Test 2")
        await wait(for: { engine.current?.remoteUniqueId == "z" }, "should start the new session")
        engine.next()
        await wait(for: { calls > afterFirstSession }, "a new play session should extend again")
    }

    // MARK: - Off

    func test_autoplayOff_leavesTheQueueAlone() async {
        let engine = makeEngine()
        engine.isAutoplayEnabled = false
        var calls = 0
        engine.autoplayProvider = { [self] _, _ in calls += 1; return [track("x")] }
        engine.play(tracks: [track("a")], context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "a" }, "should start on a")

        engine.next()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(calls, 0, "with Keep playing off, nothing should be fetched")
        XCTAssertEqual(engine.queue.map(\.remoteUniqueId), ["a"])
        XCTAssertFalse(engine.hasNext)
    }

    // With no provider wired at all, Next at the end of the queue is simply unavailable — it must
    // never resolve to "reload the track already playing".
    func test_noProvider_nextAtEndOfQueueDoesNothing() async {
        let engine = makeEngine()
        engine.play(tracks: [track("a")], context: "Test")
        await wait(for: { engine.current?.remoteUniqueId == "a" }, "should start on a")

        XCTAssertFalse(engine.hasNext)
        engine.next()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(engine.currentIndex, 0)
    }
}

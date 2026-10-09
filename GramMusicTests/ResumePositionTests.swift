import XCTest
import AVFoundation
@testable import GramMusic

/// "Resume where you left off" must apply to the track you left off on — and to nothing else.
///
/// The restored position was held in a marker that only `resume()` consumed and only `stop()`
/// cleared, so it stayed armed for the whole session after a cold launch. Playing a *different*
/// song started at 0:00 correctly, but pausing and pressing play then found the marker still set
/// and reloaded that song at the position of a track from the previous session.
@MainActor
final class ResumePositionTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: StorageKeys.playerState)
        super.tearDown()
    }

    private func track(_ id: String) -> AudioTrack {
        AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: id,
                   title: "Song \(id)", performer: "Artist", duration: 300)
    }

    private func makeEngine() -> PlayerEngine {
        PlayerEngine(fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
                     itemProvider: { _ in AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")) })
    }

    /// Write a saved session by hand — the encoder's own type is private, and the point of the
    /// test is what a *previous launch* left on disk.
    private func saveSession(track id: String, at seconds: Double) {
        let entry = """
        {"id":"\(UUID().uuidString)","track":{"chatId":1,"messageId":1,"fileId":1,\
        "remoteUniqueId":"\(id)","remoteFileId":"","title":"Song \(id)","performer":"Artist",\
        "duration":300},"origin":"context"}
        """
        let json = """
        {"entries":[\(entry)],"currentIndex":0,"currentTime":\(seconds),\
        "isShuffle":false,"repeatRaw":0}
        """
        UserDefaults.standard.set(Data(json.utf8), forKey: StorageKeys.playerState)
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

    func test_restoredSession_offersThePositionItLeftOff() {
        saveSession(track: "old", at: 95)
        let engine = makeEngine()
        engine.restoreState()

        XCTAssertEqual(engine.current?.remoteUniqueId, "old")
        XCTAssertEqual(engine.currentTime, 95, accuracy: 0.5, "the saved position is still offered")
        XCTAssertFalse(engine.isPlaying, "...but restored paused, never auto-playing")
    }

    // The bug: play something else after a cold launch, pause it, press play — and it jumped to
    // the *previous session's* position.
    func test_playingSomethingElse_dropsTheRestoredPosition() async {
        saveSession(track: "old", at: 95)
        let engine = makeEngine()
        engine.restoreState()

        engine.play(tracks: [track("new")], startAt: 0)
        await wait(for: { engine.current?.remoteUniqueId == "new" }, "the new track never loaded")
        XCTAssertLessThan(engine.currentTime, 5, "a deliberate play starts at the beginning")

        engine.pause()
        engine.resume()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(engine.current?.remoteUniqueId, "new")
        XCTAssertLessThan(engine.currentTime, 5,
                          "pressing play must not seek to where a different track was last session")
    }

    // Same trap by a different route: skipping through the queue also supersedes the marker.
    func test_skipping_dropsTheRestoredPosition() async {
        saveSession(track: "old", at: 95)
        let engine = makeEngine()
        engine.restoreState()

        engine.play(tracks: [track("a"), track("b")], startAt: 0)
        await wait(for: { engine.current?.remoteUniqueId == "a" }, "never started")
        engine.next()
        await wait(for: { engine.current?.remoteUniqueId == "b" }, "never advanced")

        engine.pause()
        engine.resume()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThan(engine.currentTime, 5)
    }

    func test_resumingTheRestoredTrackItself_stillHonoursTheSavedPosition() async {
        saveSession(track: "old", at: 95)
        let engine = makeEngine()
        engine.restoreState()

        engine.resume()   // the one case the saved position is for
        await wait(for: { engine.currentTime > 90 },
                   "resuming the track you left off on should pick it up where you left it")
    }
}

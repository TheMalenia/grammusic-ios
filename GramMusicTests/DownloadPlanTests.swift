import XCTest
import AVFoundation
@testable import GramMusic

/// What the player *asks* to be downloaded, and when it re-asks.
///
/// The engine deliberately downloads nothing itself — it declares a plan and `TelegramService`
/// schedules it. That plan is the contract: **index 0 is the track playing right now, index 1 is
/// the one that plays next, the rest is lookahead**, in true play order (manual "Add to Queue"
/// entries come before the rest of the context, because that is what will actually play).
@MainActor
final class DownloadPlanTests: XCTestCase {

    private func track(_ id: String) -> AudioTrack {
        AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: id,
                   title: "Song \(id)", performer: "Artist", duration: 100)
    }

    private func makeEngine() -> PlayerEngine {
        PlayerEngine(fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
                     itemProvider: { _ in AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")) })
    }

    private func keys(_ tracks: [AudioTrack]) -> [String] { tracks.map(\.remoteUniqueId) }

    func test_plan_isPlayingTrackThenTheQueueInPlayOrder() {
        let engine = makeEngine()
        engine.play(tracks: ["a", "b", "c", "d", "e", "f"].map(track), startAt: 0)

        XCTAssertEqual(keys(engine.downloadPlan(lookahead: 3)), ["a", "b", "c", "d"])
    }

    // Pressing play must not kick off five simultaneous downloads. The default is the playing
    // track plus exactly one: enough for an instant Next, and not a byte of the user's data spent
    // on tracks they will probably skip past.
    func test_plan_defaultsToThePlayingTrackAndOneMore() {
        let engine = makeEngine()
        engine.play(tracks: ["a", "b", "c", "d", "e", "f"].map(track), startAt: 0)

        XCTAssertEqual(keys(engine.downloadPlan()), ["a", "b"])
    }

    func test_plan_isEmptyWithNothingPlaying() {
        XCTAssertTrue(makeEngine().downloadPlan().isEmpty)
    }

    func test_plan_putsManualQueueAddsBeforeTheRestOfTheContext() {
        let engine = makeEngine()
        engine.play(tracks: ["a", "b", "c"].map(track), startAt: 0)
        engine.addToQueue(track("manual"))

        XCTAssertEqual(keys(engine.downloadPlan(lookahead: 2)), ["a", "manual", "b"],
                       "what plays next is what downloads next")
    }

    func test_plan_respectsTheLookaheadBudget() {
        let engine = makeEngine()
        engine.play(tracks: ["a", "b", "c", "d", "e"].map(track), startAt: 0)
        XCTAssertEqual(engine.downloadPlan(lookahead: 1).count, 2, "the playing track plus one")
    }

    func test_plan_doesNotWrapPastTheEndUnlessRepeatAllWill() {
        let engine = makeEngine()
        engine.play(tracks: ["a", "b"].map(track), startAt: 1)
        XCTAssertEqual(keys(engine.downloadPlan(lookahead: 3)), ["b"])

        engine.repeatMode = .all
        XCTAssertEqual(keys(engine.downloadPlan(lookahead: 3)), ["b", "a"],
                       "repeat-all means the top of the queue really is what plays next")
    }

    // Editing the queue has to re-aim downloads immediately; waiting for the next track change
    // is how a freshly-queued song ends up unbuffered when it starts.
    func test_queueEdits_republishThePlan() async {
        let engine = makeEngine()
        var published: [[String]] = []
        engine.onDownloadPlanChanged = { published.append($0.map(\.remoteUniqueId)) }

        engine.play(tracks: ["a", "b"].map(track), startAt: 0)
        published.removeAll()

        engine.addToQueue(track("manual"))
        XCTAssertEqual(published.last, ["a", "manual"], "adding to the queue re-aims downloads")

        published.removeAll()
        engine.removeFromQueue(at: IndexSet(integer: 1))   // the manual add sits right after "a"
        XCTAssertEqual(published.last?.contains("manual"), false, "and so does removing from it")
    }

    func test_stopping_clearsThePlan() {
        let engine = makeEngine()
        var published: [[String]] = []
        engine.onDownloadPlanChanged = { published.append($0.map(\.remoteUniqueId)) }
        engine.play(tracks: ["a", "b"].map(track), startAt: 0)

        engine.stop()
        XCTAssertEqual(published.last, [], "nothing is playing, so stop chasing downloads for it")
    }
}

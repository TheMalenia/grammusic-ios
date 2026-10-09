import XCTest
import AVFoundation
import SwiftData
@testable import GramMusic

@MainActor
final class ActionFeedbackTests: XCTestCase {
    private func track(_ id: String) -> AudioTrack {
        AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: id,
                   title: id, performer: "Artist", duration: 100)
    }

    private func engine() -> PlayerEngine {
        PlayerEngine(fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
                     itemProvider: { _ in AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")) })
    }

    func test_addingToQueueDoesNotPresentAConfirmation() {
        let player = engine()
        defer { player.stop() }
        player.play(tracks: [track("a"), track("b")])
        let feedback = NActionFeedback()
        feedback.enqueue(track("c"), in: player)
        XCTAssertTrue(player.entries.contains { $0.track.remoteUniqueId == "c" })
        XCTAssertEqual(player.current?.remoteUniqueId, "a")
        XCTAssertNil(feedback.message)
        XCTAssertNil(feedback.undo)
    }

    func test_oldExpiryCannotDismissANewerConfirmation() {
        let feedback = NActionFeedback()
        feedback.show("First")
        let firstID = feedback.id
        feedback.show("Second")
        feedback.dismiss(ifMatching: firstID)
        XCTAssertEqual(feedback.message, "Second")
    }

    func test_playNextDoesNotPresentAConfirmation() {
        let player = engine()
        defer { player.stop() }
        player.play(tracks: [track("a"), track("b")])
        let feedback = NActionFeedback()
        feedback.enqueue(track("c"), in: player, next: true)
        XCTAssertEqual(player.entries[player.currentIndex + 1].track.remoteUniqueId, "c")
        XCTAssertEqual(player.current?.remoteUniqueId, "a")
        XCTAssertNil(feedback.message)
    }

    func test_searchOriginIsKeptPerQueueEntryAndSurvivesPersistence() throws {
        let player = engine()
        defer { player.stop() }
        player.play(tracks: [track("searched"), track("next result")], fromSearch: true)
        player.addToQueue(track("library"))
        player.playNext(track("queued search"), fromSearch: true)
        XCTAssertTrue(player.entries.first { $0.track.remoteUniqueId == "searched" }!.fromSearch)
        XCTAssertFalse(player.entries.first { $0.track.remoteUniqueId == "library" }!.fromSearch)
        XCTAssertTrue(player.entries.first { $0.track.remoteUniqueId == "queued search" }!.fromSearch)
        let restored = try JSONDecoder().decode([QueueEntry].self, from: JSONEncoder().encode(player.entries))
        XCTAssertEqual(restored, player.entries)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(player.entries[0])) as? [String: Any])
        legacy.removeValue(forKey: "fromSearch")
        let legacyEntry = try JSONDecoder().decode(QueueEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(legacyEntry.fromSearch)
    }

    func test_newChatMusicAdvancesActivityWithoutOlderEventsMovingItBack() {
        let telegram = TelegramService(backend: MockTelegramBackend())
        telegram.chats = [TelegramChat(id: 42, title: "Music", kind: .channel, lastAudioDate: Date(timeIntervalSince1970: 100))]
        telegram.noteChatAudioActivity(chatId: 42, date: Date(timeIntervalSince1970: 200))
        telegram.noteChatAudioActivity(chatId: 42, date: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(telegram.chats[0].lastAudioDate, Date(timeIntervalSince1970: 200))
    }

    func test_restoringRemovedPlaylistTrackPreservesPositionAndNewAdditions() throws {
        let container = try ModelContainer(for: Playlist.self, TrackRef.self,
                                           configurations: .init(isStoredInMemoryOnly: true))
        let service = PlaylistService(context: container.mainContext)
        let playlist = service.create(name: "Mix")
        service.add([track("a"), track("b"), track("c")], to: playlist)
        let removed = playlist.orderedTracks[1]
        service.remove(removed, from: playlist)
        service.add(track("new"), to: playlist)
        service.restore(track("b"), to: playlist, at: 1)
        XCTAssertEqual(playlist.orderedTracks.map(\.remoteUniqueId), ["new", "b", "a", "c"])
        XCTAssertEqual(playlist.orderedTracks.map(\.order), [0, 1, 2, 3])
        service.restore(track("b"), to: playlist, at: 1)
        XCTAssertEqual(playlist.tracks.count, 4)
    }
}

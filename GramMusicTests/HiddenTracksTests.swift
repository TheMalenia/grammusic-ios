import XCTest
import SwiftData
import AVFoundation
@testable import GramMusic

@MainActor
final class HiddenTracksTests: XCTestCase {
    private func track(_ id: String) -> AudioTrack {
        AudioTrack(chatId: 123, messageId: 1, fileId: 1, remoteUniqueId: id,
                   remoteFileId: "remote-" + id, title: id, performer: "Artist", duration: 100)
    }

    func test_hiddenSongsPersistDeduplicateAndCanBeRestored() throws {
        let suite = "HiddenTracksTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HiddenTracksStore(defaults: defaults)
        store.hide([track("a"), track("a"), track("b")])
        let restored = HiddenTracksStore(defaults: defaults)
        XCTAssertEqual(restored.ids, ["a", "b"])
        XCTAssertEqual(restored.tracks.count, 2)
        restored.unhide("a")
        XCTAssertEqual(HiddenTracksStore(defaults: defaults).ids, ["b"])
        XCTAssertTrue(StorageKeys.perAccount.contains(StorageKeys.hiddenTracks))
        restored.clear()
        XCTAssertTrue(HiddenTracksStore(defaults: defaults).tracks.isEmpty)
    }

    func test_hidingPlayingSongRemovesDuplicatesAndRestoringAllowsItAgain() throws {
        let suite = "HiddenTracksTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let telegram = TelegramService(backend: MockTelegramBackend(), hiddenTracks: HiddenTracksStore(defaults: defaults))
        let player = PlayerEngine(fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
                                  itemProvider: { _ in AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")) })
        defer { player.stop() }
        telegram.onTracksHidden = { ids in player.removeHiddenTracks(ids) }
        player.play(tracks: [track("a"), track("b"), track("a")])
        telegram.hideTracks([track("a")])
        XCTAssertEqual(player.entries.map { $0.track.remoteUniqueId }, ["b"])
        XCTAssertEqual(player.current?.remoteUniqueId, "b")
        XCTAssertEqual(telegram.visible([track("a"), track("b")]).map(\.remoteUniqueId), ["b"])
        telegram.unhideTrack(track("a"))
        XCTAssertEqual(telegram.visible([track("a"), track("b")]).map(\.remoteUniqueId), ["a", "b"])
    }

    func test_bulkUnhideRestoresMixedSelectionAndKeepsOtherHiddenSongs() throws {
        let suite = "BulkUnhideTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HiddenTracksStore(defaults: defaults)
        let telegram = TelegramService(backend: MockTelegramBackend(), hiddenTracks: store)
        store.hide([track("a"), track("b"), track("other")])
        telegram.unhideTracks([track("a"), track("b"), track("visible"), track("a")])
        XCTAssertEqual(store.ids, ["other"])
        XCTAssertEqual(HiddenTracksStore(defaults: defaults).ids, ["other"])
        XCTAssertFalse(telegram.isHidden(track("visible")))
    }

    func test_bulkRemovalAndClearSearchKeepOtherPlaylistsAndAudioReferences() throws {
        let container = try ModelContainer(for: Playlist.self, TrackRef.self,
                                           configurations: .init(isStoredInMemoryOnly: true))
        let service = PlaylistService(context: container.mainContext)
        let mix = service.create(name: "Mix")
        service.add([track("a"), track("b"), track("c")], to: mix)
        service.recordSearchListen(track("a"), enabled: true)
        service.recordSearchListen(track("b"), enabled: true)
        let search = service.searchPlaylist()
        service.removeTracks([track("b"), track("c")], from: mix)
        XCTAssertEqual(mix.orderedTracks.map(\.remoteUniqueId), ["a"])
        XCTAssertEqual(mix.orderedTracks.map(\.order), [0])
        service.clearSearchPlaylist(search)
        XCTAssertTrue(search.tracks.isEmpty)
        XCTAssertTrue(search.isSearch)
        XCTAssertEqual(mix.tracks.count, 1)
        service.recordSearchListen(track("c"), enabled: true)
        XCTAssertEqual(search.orderedTracks.map(\.remoteUniqueId), ["c"])
    }

    func test_inlineResultsHaveNoMessageToReport() {
        let telegram = TelegramService(backend: MockTelegramBackend())
        let inline = AudioTrack(chatId: 0, messageId: 0, fileId: 1, remoteUniqueId: "inline",
                                title: "Result", performer: "Artist", duration: 100)
        XCTAssertFalse(telegram.isReportable(track: inline))
        let invalid = AudioTrack(chatId: 123, messageId: 0, fileId: 1, remoteUniqueId: "invalid",
                                 title: "Result", performer: "Artist", duration: 100)
        XCTAssertFalse(telegram.isReportable(track: invalid))
    }
}

import XCTest
import SwiftData
@testable import GramMusic

/// Where a freshly added track lands in a playlist.
@MainActor
final class PlaylistOrderTests: XCTestCase {

    private var container: ModelContainer!
    private var service: PlaylistService!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(for: Playlist.self, TrackRef.self,
                                       configurations: .init(isStoredInMemoryOnly: true))
        service = PlaylistService(context: container.mainContext)
    }

    override func tearDown() async throws {
        service = nil
        container = nil
        try await super.tearDown()
    }

    private func track(_ id: String) -> AudioTrack {
        AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: id,
                   title: "Song \(id)", performer: "Artist", duration: 100)
    }

    private func ids(_ playlist: Playlist) -> [String] {
        playlist.orderedTracks.map(\.remoteUniqueId)
    }

    func test_searchSavingIsOffByDefaultAndPersistsWhenEnabled() throws {
        let suite = "SearchSettingsTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.saveSearchResults)
        settings.saveSearchResults = true
        XCTAssertTrue(AppSettings(defaults: defaults).saveSearchResults)
    }

    func test_disabledSearchDoesNotCreateAPlaylist() throws {
        service.recordSearchListen(track("a"), enabled: false)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Playlist>()).isEmpty)
    }

    func test_searchListensCollectWithoutDuplicates() throws {
        service.recordSearchListen(track("a"), enabled: true)
        service.recordSearchListen(track("b"), enabled: true)
        service.recordSearchListen(track("a"), enabled: true)
        service.recordSearchListen(track("c"), enabled: true)
        service.recordSearchListen(track("d"), enabled: true)
        service.recordSearchListen(track("b"), enabled: true)
        let playlists = try container.mainContext.fetch(FetchDescriptor<Playlist>())
        let search = try XCTUnwrap(playlists.first { $0.isSearch })
        XCTAssertEqual(playlists.count, 1)
        XCTAssertEqual(ids(search), ["d", "c", "b", "a"])
        service.recordSearchListen(track("e"), enabled: false)
        XCTAssertEqual(ids(search), ["d", "c", "b", "a"])
    }

    func test_searchCollectionDoesNotUseAUserPlaylistWithTheSameName() throws {
        let userPlaylist = service.create(name: "Search")
        service.recordSearchListen(track("a"), enabled: true)
        let search = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<Playlist>()).first { $0.isSearch })
        service.rename(search, to: "Discoveries")
        service.recordSearchListen(track("b"), enabled: true)
        XCTAssertTrue(userPlaylist.tracks.isEmpty)
        XCTAssertEqual(ids(search), ["b", "a"])
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Playlist>()).count, 2)
    }

    func test_searchPlaylistIsAnEmptyDefaultPlaylistAndRejectsManualAdditions() {
        let search = service.searchPlaylist()
        XCTAssertTrue(search.isSmart)
        XCTAssertTrue(search.isPinned)
        XCTAssertEqual(search.symbolName, "magnifyingglass")
        XCTAssertTrue(search.tracks.isEmpty)
        service.add(track("manual"), to: search)
        service.add([track("manual")], to: search)
        XCTAssertTrue(search.tracks.isEmpty)
        service.recordSearchListen(track("listened"), enabled: true)
        XCTAssertEqual(ids(search), ["listened"])
    }

    func test_newMusicUpdatesPlaylistActivityButDuplicateResultsDoNot() {
        let older = service.create(name: "Older")
        let newer = service.create(name: "Newer")
        let past = Date(timeIntervalSince1970: 100)
        older.updatedAt = past
        newer.updatedAt = Date(timeIntervalSince1970: 200)
        service.add(track("a"), to: older)
        XCTAssertGreaterThan(older.updatedAt ?? past, newer.updatedAt ?? past)
        XCTAssertEqual([newer, older].sortedForLibrary.first?.name, "Older")
        let activity = older.updatedAt
        service.add(track("a"), to: older)
        XCTAssertEqual(older.updatedAt, activity)
    }

    // Appending put a newly added track at the bottom of a long playlist, where the user had to
    // scroll to find the thing they had just added.
    func test_addedTracksLandAtTheTop() {
        let playlist = service.create(name: "Mix")
        service.add(track("first"), to: playlist)
        service.add(track("second"), to: playlist)
        service.add(track("third"), to: playlist)

        XCTAssertEqual(ids(playlist), ["third", "second", "first"])
    }

    func test_ordersStayContiguous() {
        let playlist = service.create(name: "Mix")
        for id in ["a", "b", "c"] { service.add(track(id), to: playlist) }

        XCTAssertEqual(playlist.orderedTracks.map(\.order), [0, 1, 2],
                       "shifting on insert must not leave gaps or duplicates")
    }

    func test_addingADuplicate_changesNothing() {
        let playlist = service.create(name: "Mix")
        service.add(track("a"), to: playlist)
        service.add(track("b"), to: playlist)
        service.add(track("a"), to: playlist)

        XCTAssertEqual(ids(playlist), ["b", "a"], "a duplicate must not reorder the playlist")
        XCTAssertEqual(playlist.trackCount, 2)
    }

    func test_removingKeepsTheRestInOrder() {
        let playlist = service.create(name: "Mix")
        for id in ["a", "b", "c"] { service.add(track(id), to: playlist) }
        guard let middle = playlist.orderedTracks.first(where: { $0.remoteUniqueId == "b" }) else {
            return XCTFail("missing track")
        }

        service.remove(middle, from: playlist)
        XCTAssertEqual(ids(playlist), ["c", "a"])
        XCTAssertEqual(playlist.orderedTracks.map(\.order), [0, 1])
    }
    func test_batchAdditionPreservesSelectionOrderAndSkipsDuplicates() {
        let playlist = service.create(name: "Destination")
        service.add(track("existing"), to: playlist)
        service.add([track("a"), track("existing"), track("b"), track("a")], to: playlist)

        XCTAssertEqual(ids(playlist), ["a", "b", "existing"])
        XCTAssertEqual(playlist.orderedTracks.map(\.order), [0, 1, 2])
    }

    func test_copyToAnotherPlaylistKeepsSourceIntact() {
        let source = service.create(name: "Source")
        let destination = service.create(name: "Destination")
        service.add([track("a"), track("b")], to: source)
        service.add(source.orderedTracks.map(\.audioTrack), to: destination)

        XCTAssertEqual(ids(source), ["a", "b"])
        XCTAssertEqual(ids(destination), ["a", "b"])
        XCTAssertFalse(source.orderedTracks[0] === destination.orderedTracks[0])
    }

}

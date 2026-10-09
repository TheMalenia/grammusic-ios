import XCTest
import SwiftData
@testable import GramMusic

/// Exercises the SwiftData mutations behind the Profile Music smart playlist — the empty→add→add
/// replace cycle that mirrors the user's Telegram profile audio. A delete-while-enumerating bug
/// in `replaceProfileAudio` would crash here (CoreData "collection mutated") rather than in the app.
@MainActor
final class ProfileAudioMirrorTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Playlist.self, TrackRef.self, configurations: config)
        return ModelContext(container)
    }

    private func track(_ id: String) -> AudioTrack {
        AudioTrack(chatId: 0, messageId: 0, fileId: 1, remoteUniqueId: id, remoteFileId: "r-\(id)",
                   title: "Song \(id)", performer: "Artist", duration: 100, fileName: "\(id).mp3")
    }

    func test_replaceProfileAudio_emptyThenAddThenReplace() throws {
        let service = PlaylistService(context: try makeContext())

        // Pre-built empty playlist (like the Library seed).
        _ = service.profilePlaylist()
        XCTAssertEqual(service.existingProfile()?.trackCount, 0)

        // First add (empty → 1).
        service.replaceProfileAudio(with: [track("a")])
        XCTAssertEqual(service.existingProfile()?.trackCount, 1)

        // Replace with a longer ordered list (1 → 3): deletes the existing ref then re-inserts.
        service.replaceProfileAudio(with: [track("b"), track("a"), track("c")])
        let p = try XCTUnwrap(service.existingProfile())
        XCTAssertEqual(p.trackCount, 3)
        XCTAssertEqual(p.orderedTracks.map(\.remoteUniqueId), ["b", "a", "c"])

        // Replace down to empty (3 → 0): the full delete path on a multi-track relationship.
        service.replaceProfileAudio(with: [])
        XCTAssertEqual(service.existingProfile()?.trackCount, 0)
    }

    func test_removeUnavailableTracks_removesOnlyMatchingTracksAndReindexes() throws {
        let service = PlaylistService(context: try makeContext())
        let playlist = service.create(name: "Roadtrip")

        service.add(track("track1"), to: playlist)
        service.add(track("track2"), to: playlist)
        service.add(track("track3"), to: playlist)
        service.add(track("track4"), to: playlist)

        XCTAssertEqual(playlist.trackCount, 4)

        // Remove track2 and track4
        let removed = service.removeUnavailableTracks(from: playlist, unavailableIds: ["track2", "track4", "nonexistent"])
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(playlist.trackCount, 2)

        // Newest-first: the adds above leave [4, 3, 2, 1], so dropping 2 and 4 leaves [3, 1].
        let remaining = playlist.orderedTracks
        XCTAssertEqual(remaining.map(\.remoteUniqueId), ["track3", "track1"])
        XCTAssertEqual(remaining[0].order, 0)
        XCTAssertEqual(remaining[1].order, 1)
    }

    // The "Add to playlist" sheet listed Profile Music alongside the local playlists and added to
    // it with `PlaylistService.add` — so the row ticked, the song never reached Telegram, and the
    // next `replaceProfileAudio` (which runs on every connection recovery) reconciled it away.
    // A local add to the mirror is now a no-op; the write has to go through TelegramService.
    func test_localAddToProfileMusic_isRejected() throws {
        let service = PlaylistService(context: try makeContext())
        let profile = service.profilePlaylist()

        service.add(track("sneaky"), to: profile)
        XCTAssertEqual(profile.trackCount, 0, "a local add must not fake profile membership")

        // The mirror is still the way tracks get in.
        service.replaceProfileAudio(with: [track("sneaky")])
        XCTAssertEqual(service.existingProfile()?.trackCount, 1)
    }

    // The heart shown in lists is derived from TelegramService.favoriteIds, not from a per-view
    // @State copy. Toggling from anywhere must move that shared mirror, so every surface agrees.
    func test_favoriteMirror_staysInSyncWithSwiftData() throws {
        let context = try makeContext()
        let service = TelegramService(backend: MockTelegramBackend())
        service.attachModelContext(context)
        let t = track("fav")

        XCTAssertFalse(service.isFavorite(t))

        XCTAssertTrue(service.toggleFavorite(t))
        XCTAssertTrue(service.isFavorite(t), "mirror must reflect the like immediately")
        XCTAssertTrue(PlaylistService(context: context).isFavorite(t), "SwiftData must agree")

        XCTAssertFalse(service.toggleFavorite(t))
        XCTAssertFalse(service.isFavorite(t))
        XCTAssertFalse(PlaylistService(context: context).isFavorite(t))
    }

    // A relaunch must rebuild the mirror from the stored Favorites playlist, or previously-liked
    // tracks would silently show an empty heart.
    func test_favoriteMirror_seededFromStoredPlaylistOnAttach() throws {
        let context = try makeContext()
        let t = track("fav")
        PlaylistService(context: context).toggleFavorite(t)

        let fresh = TelegramService(backend: MockTelegramBackend())
        XCTAssertFalse(fresh.isFavorite(t), "nothing known before the context is attached")
        fresh.attachModelContext(context)
        XCTAssertTrue(fresh.isFavorite(t), "mirror should be seeded from the stored playlist")
    }
}

import Foundation
import SwiftData

extension LibrarySnapshot {

    /// Build a snapshot from the live services.
    ///
    /// Deliberately reads only what is **already in memory**, so opening the assistant is
    /// instant and works offline. Chats and artists the user has never opened appear here as
    /// *names with no tracks*; `SnapshotHydrator` fetches those on demand once a request actually
    /// names one, so nothing is loaded speculatively.
    ///
    /// - Parameters:
    ///   - telegram: source of artists, chats, caches, recents and play counts.
    ///   - playlists: every `Playlist`, used to find the Favorites and Downloaded mirrors.
    ///   - importedChatIds: which chats the user imported. Used for *ordering* only — every chat
    ///     with audio is reachable, imported ones just rank first.
    @MainActor
    static func live(telegram: TelegramService,
                     playlists: [Playlist],
                     importedChatIds: (Int64) -> Bool) -> LibrarySnapshot {
        var snapshot = LibrarySnapshot()

        snapshot.artists = telegram.sortedFollowedArtists

        // Every chat with audio, not just the imported ones — the assistant should be able to
        // reach a channel the user hasn't added to their Library. Imported chats come first so
        // that when the roster is capped for a model, the most relevant names survive.
        // Secret chats are excluded outright: they are end-to-end encrypted, and surfacing their
        // titles into a list built for a language model is not a judgement call.
        let withAudio = telegram.chats.filter { ($0.audioCount ?? 0) > 0 && $0.kind != .secret }
        let chats = withAudio.filter { importedChatIds($0.id) }
            + withAudio.filter { !importedChatIds($0.id) }
        snapshot.chats = chats.map {
            .init(id: $0.id, title: $0.title, isPrivate: $0.kind == .privateChat)
        }

        for chat in chats {
            let cached = telegram.cachedChatAudio(chat.id)
            if !cached.isEmpty { snapshot.tracksByChat[chat.id] = cached }
        }
        for artist in snapshot.artists {
            let cached = telegram.cachedArtistTracks(artist)
            if !cached.isEmpty { snapshot.tracksByArtist[artist] = cached }
        }

        snapshot.favorites = playlists.first(where: \.isFavorites)?
            .orderedTracks.map(\.audioTrack) ?? []
        snapshot.downloaded = playlists.first(where: \.isDownloads)?
            .orderedTracks.map(\.audioTrack) ?? []

        snapshot.recentlyPlayed = telegram.recentlyPlayed
        snapshot.playCounts = telegram.playCounts

        return snapshot
    }

    /// Whether there is enough here to attempt anything. An empty library should say so plainly
    /// rather than letting the user type into a box that cannot answer.
    var hasEnoughToCompose: Bool {
        !artists.isEmpty || !chats.isEmpty || !favorites.isEmpty
            || !downloaded.isEmpty || !recentlyPlayed.isEmpty
    }
}

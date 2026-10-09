import Foundation
import SwiftData

/// A user-created playlist — the feature Telegram itself lacks. Holds an ordered set of
/// references to audio that lives in the user's Telegram.
@Model
final class Playlist {
    var name: String
    var createdAt: Date
    /// Content changes, used alongside last-opened activity for Library Recents.
    var updatedAt: Date? = nil
    /// The special, auto-managed "Favorites" playlist backing the like/heart feature.
    var isFavorites: Bool = false
    /// The special, auto-managed "Downloaded" playlist that collects downloaded tracks.
    var isDownloads: Bool = false
    /// The special "Profile Music" playlist — a mirror of the songs the user shows on their own
    /// Telegram profile (`getUserProfileAudios`). Unlike Favorites/Downloaded its membership and
    /// order live on the Telegram server; edits here are pushed back via `TelegramService`.
    var isProfile: Bool = false
    /// Stable identity for the opt-in playlist collecting search results.
    var isSearch: Bool = false
    /// Pinned playlists sort to the top of the library/home.
    var isPinned: Bool = false
    var playCount: Int = 0
    /// User-chosen cover image (JPEG bytes). When non-nil, shown instead of the auto-generated
    /// seeded artwork or first-track cover.
    @Attribute(.externalStorage) var coverImageData: Data?

    @Relationship(deleteRule: .cascade, inverse: \TrackRef.playlist)
    var tracks: [TrackRef]

    init(name: String, coverImageData: Data? = nil) {
        self.name = name
        let now = Date.now
        self.createdAt = now
        self.updatedAt = now
        self.coverImageData = coverImageData
        self.tracks = []
    }

    var symbolName: String {
        if isFavorites { return "heart.fill" }
        if isDownloads { return "arrow.down.circle.fill" }
        if isProfile { return "music.mic" }
        if isSearch { return "magnifyingglass" }
        return "music.note.list"
    }

    /// Smart playlists (Favorites / Downloaded / Profile Music) are auto-managed and not
    /// user-deletable.
    var isSmart: Bool { isFavorites || isDownloads || isProfile || isSearch }

    func contains(_ track: AudioTrack) -> Bool {
        tracks.contains { $0.remoteUniqueId == track.remoteUniqueId }
    }

    /// Tracks in their user-defined order.
    var orderedTracks: [TrackRef] {
        tracks.sorted { $0.order < $1.order }
    }

    var trackCount: Int { tracks.count }

    var totalDuration: Int { tracks.reduce(0) { $0 + $1.duration } }

    var formattedDuration: String {
        let total = totalDuration
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h) hr \(m) min" }
        return "\(m) min"
    }
}

extension Playlist {
    /// Key for the Library pin store. Name-based so it's **stable across launches** (a
    /// `PersistentIdentifier`'s encoded form is not reliably stable, which made pins reset on
    /// every launch). Two playlists sharing a name share pin state — an accepted edge case;
    /// duplicate keys can't crash the pin map (callers de-dupe / uniquing-merge).
    var pinKey: String { "p:\(name)" }
}

extension Array where Element == Playlist {
    var sortedByPlays: [Playlist] {
        sorted { a, b in
            if a.playCount != b.playCount {
                return a.playCount > b.playCount
            }
            return (a.updatedAt ?? a.createdAt) > (b.updatedAt ?? b.createdAt)
        }
    }

    /// Library/Home ordering: Favorites first, then Downloaded, then Profile Music, then pinned,
    /// then the rest (most-recently-created first within each group).
    var sortedForLibrary: [Playlist] {
        func rank(_ p: Playlist) -> Int {
            if p.isFavorites { return 0 }
            if p.isDownloads { return 1 }
            if p.isProfile { return 2 }
            if p.isSearch { return 3 }
            if p.isPinned { return 4 }
            return 5
        }
        return sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : (a.updatedAt ?? a.createdAt) > (b.updatedAt ?? b.createdAt)
        }
    }
}

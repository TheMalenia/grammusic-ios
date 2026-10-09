import Foundation

/// A structured description of the playlist the user asked for — the *only* thing a **Composer**
/// is ever allowed to produce.
///
/// The deliberate omission is tracks. A Recipe names artists, chats and moods; it never names a
/// song. Track selection is `RecipeSelector`'s job, and it draws exclusively from `AudioTrack`s
/// already in the user's library. A language model that invents "Radiohead – Karma Police" when
/// the user has no such file therefore cannot produce a broken playlist — the invented title has
/// nowhere to go. Everything the user sees came off their own Telegram.
///
/// `artists` and `chats` are *names as the user said them*, not identifiers: fuzzy, possibly
/// misspelled, possibly not present at all. `RecipeSelector` matches them against the real
/// library and reports what it couldn't place.
struct PlaylistRecipe: Codable, Equatable, Sendable {

    /// Display name for the playlist. Never empty by the time it reaches `RecipeSelector`.
    var name: String

    /// Performer names the user asked for, as spoken.
    var artists: [String] = []

    /// Chat/channel titles the user asked for, as spoken.
    var chats: [String] = []

    /// Free-text mood words ("chill", "workout"). Recorded for the playlist name and for future
    /// ranking; they intentionally do **not** filter, because nothing on-device knows what a track
    /// sounds like. Promising mood filtering we can't deliver is worse than not offering it.
    var moods: [String] = []

    /// Which slice of the library to draw from when no artist or chat narrows it.
    var scope: Scope = .everything

    /// How many tracks to aim for. Clamped by `RecipeSelector` to `Limits`.
    var trackCount: Int = 25

    /// Ordering of the result.
    var sort: Sort = .relevance

    enum Scope: String, Codable, Sendable, CaseIterable {
        case favorites
        case downloaded
        case recentlyPlayed
        case everything
    }

    enum Sort: String, Codable, Sendable, CaseIterable {
        /// Grouped by the entity that matched, in the order the user named them.
        case relevance
        /// Highest play count first.
        case mostPlayed
        /// Newest Telegram message first.
        case newest
        /// Deterministically shuffled (seeded by the recipe name, so a preview doesn't reshuffle
        /// under the user between render and confirm).
        case random
    }

    enum Limits {
        static let minTracks = 1
        static let maxTracks = 100
        static let defaultTracks = 25
    }

    /// A recipe with every field at its default — the fallback when a Composer produces nothing
    /// usable but the user still deserves a playlist.
    static func fallback(named name: String = "New Playlist") -> PlaylistRecipe {
        PlaylistRecipe(name: name)
    }
}

// MARK: - Lenient decoding

/// Hand-written decoding because synthesized `Codable` **ignores property defaults**: a reply that
/// omits `artists` throws `keyNotFound` even though the property defaults to `[]`. Models omit
/// empty fields routinely, and a small one may also emit a `scope` or `sort` string outside our
/// enum. Neither should cost the user their playlist, so every field degrades to its default
/// instead of failing the whole decode. `name` is the sole required key — without it there is no
/// request to act on.
extension PlaylistRecipe {

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name))

        func strings(_ key: CodingKeys) -> [String] {
            (try? c.decodeIfPresent([String].self, forKey: key)).flatMap { $0 } ?? []
        }

        artists = strings(.artists)
        chats = strings(.chats)
        moods = strings(.moods)

        let rawScope = (try? c.decodeIfPresent(String.self, forKey: .scope)).flatMap { $0 }
        scope = rawScope.flatMap(Scope.init(rawValue:)) ?? .everything

        let rawSort = (try? c.decodeIfPresent(String.self, forKey: .sort)).flatMap { $0 }
        sort = rawSort.flatMap(Sort.init(rawValue:)) ?? .relevance

        trackCount = (try? c.decodeIfPresent(Int.self, forKey: .trackCount))
            .flatMap { $0 } ?? Limits.defaultTracks
    }
}

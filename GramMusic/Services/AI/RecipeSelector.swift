import Foundation

/// Turns a `PlaylistRecipe` into real tracks from a `LibrarySnapshot`.
///
/// Deliberately *not* called a Resolver — `CONTEXT.md` pins that term for the tiered
/// attribute lookup (memory → disk → produce). This is a different thing: a pure, synchronous
/// projection of a recipe onto the user's library, with no caching, no I/O and no async.
///
/// It is also where the feature's quality lives. A Composer only decides *which names* were meant;
/// everything about which songs come back, in what order, and what the user is told went missing
/// is decided here, deterministically, and is covered by tests.
enum RecipeSelector {

    /// The outcome of applying a recipe, including what couldn't be honoured.
    ///
    /// The unmatched lists matter as much as the tracks: silently dropping a name the user typed
    /// is how an assistant feels broken. The UI reports them.
    struct Selection: Equatable, Sendable {
        var name: String
        var tracks: [AudioTrack]

        /// Roster names that were found, in the order the recipe listed them.
        var matchedArtists: [String] = []
        var matchedChats: [LibrarySnapshot.Chat] = []

        /// Names from the recipe that matched nothing in the library.
        var unmatchedArtists: [String] = []
        var unmatchedChats: [String] = []

        /// Mood words carried through from the recipe. Recorded, never used to filter — see
        /// `PlaylistRecipe.moods`.
        var moods: [String] = []

        var isEmpty: Bool { tracks.isEmpty }

        /// True when the user named things and none of them existed — the case that needs an
        /// apology rather than a playlist.
        var missedEverything: Bool {
            tracks.isEmpty && !(unmatchedArtists.isEmpty && unmatchedChats.isEmpty)
        }
    }

    // MARK: - Entry point

    static func select(_ recipe: PlaylistRecipe, from snapshot: LibrarySnapshot) -> Selection {
        var selection = Selection(name: displayName(for: recipe), tracks: [], moods: recipe.moods)

        // 1. Resolve the names the recipe asked for against names that actually exist.
        var pools: [[AudioTrack]] = []

        for spoken in recipe.artists {
            guard let name = TextMatch.best(spoken, in: snapshot.artists) else {
                selection.unmatchedArtists.append(spoken)
                continue
            }
            selection.matchedArtists.append(name)
            pools.append(tracks(forArtist: name, in: snapshot))
        }

        for spoken in recipe.chats {
            guard let title = TextMatch.best(spoken, in: snapshot.chats.map(\.title)),
                  let chat = snapshot.chats.first(where: { $0.title == title }) else {
                selection.unmatchedChats.append(spoken)
                continue
            }
            selection.matchedChats.append(chat)
            pools.append(snapshot.tracksByChat[chat.id] ?? [])
        }

        // 2. With nothing named (or nothing found), fall back to the scope. A recipe that named
        //    only things we don't have must NOT quietly become "here's your whole library" — that
        //    looks like the request was ignored. `missedEverything` reports it instead.
        if pools.isEmpty {
            guard selection.unmatchedArtists.isEmpty && selection.unmatchedChats.isEmpty else {
                return selection
            }
            pools = [scopePool(recipe.scope, in: snapshot)]
        }

        // 3. Interleave rather than concatenate, so "Radiohead and LoFi Beats" gives a mix rather
        //    than 25 Radiohead tracks and nothing else when the cap bites.
        var merged = interleave(pools)

        // 4. Constrain to the scope even when names matched — "downloaded Radiohead" is one
        //    request, not two.
        if recipe.scope != .everything {
            let allowed = Set(scopePool(recipe.scope, in: snapshot).map(\.remoteUniqueId))
            let narrowed = merged.filter { allowed.contains($0.remoteUniqueId) }
            // An empty intersection means the scope wiped out a genuine match. Keep the match:
            // returning the artist's tracks un-narrowed beats returning nothing.
            if !narrowed.isEmpty { merged = narrowed }
        }

        selection.tracks = Array(order(merged, by: recipe.sort, in: snapshot, seed: recipe.name)
            .prefix(clamp(recipe.trackCount)))
        return selection
    }

    // MARK: - Pools

    /// Artist tracks, preferring the pre-keyed cache and falling back to a scan by performer.
    /// The scan matters because `tracksByArtist` is only populated for artists whose screen the
    /// user has opened.
    private static func tracks(forArtist name: String, in snapshot: LibrarySnapshot) -> [AudioTrack] {
        if let exact = snapshot.tracksByArtist[name], !exact.isEmpty { return exact }
        let normalized = TextMatch.normalized(name)
        if let keyed = snapshot.tracksByArtist.first(where: { TextMatch.normalized($0.key) == normalized }) {
            if !keyed.value.isEmpty { return keyed.value }
        }
        return snapshot.allTracks.filter { TextMatch.normalized($0.performer) == normalized }
    }

    private static func scopePool(_ scope: PlaylistRecipe.Scope,
                                  in snapshot: LibrarySnapshot) -> [AudioTrack] {
        switch scope {
        case .favorites: snapshot.favorites
        case .downloaded: snapshot.downloaded
        case .recentlyPlayed: snapshot.recentlyPlayed
        case .everything: snapshot.allTracks
        }
    }

    // MARK: - Shaping

    /// Round-robin across pools, dropping duplicates. Preserves each pool's own order.
    private static func interleave(_ pools: [[AudioTrack]]) -> [AudioTrack] {
        var seen = Set<String>()
        var out: [AudioTrack] = []
        var index = 0
        let deepest = pools.map(\.count).max() ?? 0
        while index < deepest {
            for pool in pools where index < pool.count {
                let track = pool[index]
                if seen.insert(track.remoteUniqueId).inserted { out.append(track) }
            }
            index += 1
        }
        return out
    }

    private static func order(_ tracks: [AudioTrack], by sort: PlaylistRecipe.Sort,
                              in snapshot: LibrarySnapshot, seed: String) -> [AudioTrack] {
        switch sort {
        case .relevance:
            return tracks
        case .mostPlayed:
            return tracks.enumerated().sorted { lhs, rhs in
                let l = snapshot.playCounts[lhs.element.remoteUniqueId] ?? 0
                let r = snapshot.playCounts[rhs.element.remoteUniqueId] ?? 0
                if l != r { return l > r }
                return lhs.offset < rhs.offset      // stable: equal counts keep interleave order
            }.map(\.element)
        case .newest:
            return tracks.enumerated().sorted { lhs, rhs in
                let l = lhs.element.date ?? 0
                let r = rhs.element.date ?? 0
                if l != r { return l > r }
                return lhs.offset < rhs.offset
            }.map(\.element)
        case .random:
            // Seeded, so the preview the user confirms is the playlist they get. An unseeded
            // shuffle would reshuffle on every SwiftUI re-render.
            var generator = SeededGenerator(seed: seed)
            return tracks.shuffled(using: &generator)
        }
    }

    private static func clamp(_ count: Int) -> Int {
        min(max(count, PlaylistRecipe.Limits.minTracks), PlaylistRecipe.Limits.maxTracks)
    }

    private static func displayName(for recipe: PlaylistRecipe) -> String {
        let trimmed = recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Playlist" : trimmed
    }
}

/// A tiny deterministic PRNG so `.random` is reproducible from a seed string.
/// SplitMix64 — good enough for shuffling a playlist, and stable across launches and platforms
/// (unlike `hashValue`, which is per-process seeded).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a offset basis
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        state = hash == 0 ? 0x9E37_79B9_7F4A_7C15 : hash
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

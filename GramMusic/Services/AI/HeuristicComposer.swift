import Foundation

/// A `PlaylistComposer` that parses the request with rules instead of a model.
///
/// Not a stub. It is the path that runs when the device is offline, when a provider quota is
/// exhausted, when a request times out, and on every device that can't run an on-device model —
/// which, for a free or rate-limited provider, is a large share of real usage. It needs no key,
/// no proxy and no network, and it answers instantly.
///
/// The trick that makes rule-based parsing viable here is that it doesn't parse English. It is
/// handed the roster of names that exist and scans the sentence for them (`TextMatch.mentions`).
/// "some chill radiohead and lofi beats" needs no grammar — two known names are simply present.
/// Grammar is only consulted for the small closed vocabularies: counts, scope and sort.
struct HeuristicComposer: PlaylistComposer {

    init() {}

    func compose(_ request: String, roster: ComposerRoster) async throws -> ComposerReply {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .needsMore("Tell me an artist or a chat to build from.")
        }

        var artists = TextMatch.mentions(of: roster.artists, in: text)
        let chats = TextMatch.mentions(of: roster.chats, in: text)
        let scope = detectScope(in: text)
        let sort = detectSort(in: text)
        let moods = detectMoods(in: text)
        let count = detectCount(in: text) ?? PlaylistRecipe.Limits.defaultTracks

        // Nothing in the roster matched, but the user clearly named *something*. Hand the leftover
        // words on as an artist candidate so the hydrator can put them through Telegram search —
        // that is what lets the assistant reach performers the user has never followed. If search
        // also finds nothing, `RecipeSelector` reports it as unmatched; nothing is invented.
        if artists.isEmpty && chats.isEmpty, let residual = residualPhrase(in: text) {
            artists = [residual]
        }

        // Nothing recognisable at all. Say so plainly rather than inventing a request — a wrong
        // playlist built confidently is worse than a question.
        if artists.isEmpty && chats.isEmpty && moods.isEmpty
            && scope == .everything && detectCount(in: text) == nil {
            return .needsMore("Tell me an artist, a chat, or something like “20 from my favourites”.")
        }

        let recipe = PlaylistRecipe(name: suggestName(artists: artists, chats: chats, moods: moods, scope: scope),
                                    artists: artists,
                                    chats: chats,
                                    moods: moods,
                                    scope: scope,
                                    trackCount: count,
                                    sort: sort)

        return ComposerReply(reply: summary(for: recipe), recipe: recipe, clarification: nil)
    }

    // MARK: - Closed vocabularies

    private func detectScope(in text: String) -> PlaylistRecipe.Scope {
        let t = TextMatch.normalized(text)
        if t.contains("favorite") || t.contains("favourite") || t.contains("liked") || t.contains("loved") {
            return .favorites
        }
        if t.contains("download") || t.contains("offline") || t.contains("saved offline") {
            return .downloaded
        }
        if t.contains("recently played") || t.contains("recent") || t.contains("lately") {
            return .recentlyPlayed
        }
        return .everything
    }

    private func detectSort(in text: String) -> PlaylistRecipe.Sort {
        let t = TextMatch.normalized(text)
        if t.contains("most played") || t.contains("top") || t.contains("on repeat") || t.contains("favourites first") {
            return .mostPlayed
        }
        if t.contains("newest") || t.contains("latest") || t.contains("new") || t.contains("fresh") {
            return .newest
        }
        if t.contains("random") || t.contains("shuffle") || t.contains("surprise") {
            return .random
        }
        return .relevance
    }

    /// Mood words we're willing to echo back in a playlist name. Recognising a mood does not make
    /// it filter anything (see `PlaylistRecipe.moods`) — it makes the name feel like an answer.
    private static let moodWords: Set<String> = [
        "chill", "chilled", "calm", "relaxing", "mellow", "sad", "happy", "upbeat",
        "energetic", "workout", "gym", "focus", "study", "sleep", "party", "driving",
        "morning", "night", "summer", "winter", "romantic", "angry", "hype"
    ]

    private func detectMoods(in text: String) -> [String] {
        let words = TextMatch.tokens(text)
        var seen = Set<String>()
        return words.filter { Self.moodWords.contains($0) && seen.insert($0).inserted }
    }

    /// First bare integer in the sentence, when it's plausibly a track count. Years and durations
    /// are excluded — "songs from 2019" is not a request for 2019 tracks.
    private func detectCount(in text: String) -> Int? {
        let scanner = TextMatch.normalized(text).split(separator: " ")
        for word in scanner {
            guard let value = Int(word) else { continue }
            guard value >= PlaylistRecipe.Limits.minTracks,
                  value <= PlaylistRecipe.Limits.maxTracks else { continue }
            return value
        }
        return nil
    }

    /// The words left after every word we understand structurally is removed — a plausible
    /// artist or song name to search for. Returns `nil` when nothing meaningful survives, so a
    /// sentence of pure filler doesn't become a doomed search.
    private func residualPhrase(in text: String) -> String? {
        let leftovers = TextMatch.tokens(text).filter {
            !Self.moodWords.contains($0) && !Self.structuralWords.contains($0) && Int($0) == nil
        }
        guard !leftovers.isEmpty else { return nil }
        // Title-cased: this becomes a playlist name as well as a search term, and "aphex twin"
        // reads like a bug on a playlist cover.
        let phrase = leftovers.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return phrase.count >= 3 ? phrase : nil
    }

    /// Words that describe the *shape* of the request rather than name anything in it. Removing
    /// them is what turns "play me some songs by aphex twin" into "aphex twin".
    private static let structuralWords: Set<String> = [
        "play", "make", "build", "create", "give", "me", "some", "something", "songs", "song",
        "tracks", "track", "music", "playlist", "mix", "from", "by", "with", "for", "please",
        "my", "i", "want", "like", "stuff", "put", "together", "list", "all", "any", "more",
        "favourites", "favorites", "favourite", "favorite", "liked", "loved", "downloaded",
        "downloads", "offline", "recently", "recent", "played", "lately", "most", "top",
        "repeat", "newest", "latest", "new", "fresh", "random", "shuffle", "surprise", "on", "in"
    ]

    // MARK: - Naming

    private func suggestName(artists: [String], chats: [String],
                             moods: [String], scope: PlaylistRecipe.Scope) -> String {
        let mood = moods.first.map { $0.prefix(1).uppercased() + $0.dropFirst() }

        if let subject = artists.first ?? chats.first {
            if let mood { return "\(mood) \(subject)" }
            if artists.count + chats.count > 1 { return "\(subject) & More" }
            return subject
        }
        if let mood { return "\(mood) Mix" }

        return switch scope {
        case .favorites: "From Your Favorites"
        case .downloaded: "From Your Downloads"
        case .recentlyPlayed: "On Rotation"
        case .everything: "New Playlist"
        }
    }

    private func summary(for recipe: PlaylistRecipe) -> String {
        var sources: [String] = recipe.artists + recipe.chats
        if sources.isEmpty {
            sources = switch recipe.scope {
            case .favorites: ["your favorites"]
            case .downloaded: ["your downloads"]
            case .recentlyPlayed: ["what you've played lately"]
            case .everything: ["your library"]
            }
        }
        return "Building “\(recipe.name)” — \(recipe.trackCount) tracks from \(list(sources))."
    }

    private func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}

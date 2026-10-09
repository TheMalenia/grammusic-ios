import Foundation

/// Looks up lyrics from LRCLIB's public API (free, keyless, https://lrclib.net) by a track's
/// title + artist + duration. Preferred over embedded file lyrics when online. Prefers
/// *synced* (timestamped LRC) lyrics, falling back to plain. Best-effort: any failure returns
/// nil so the caller can show the "no lyrics" state.
///
/// Privacy note: this sends the track's title, artist, and duration to LRCLIB's public
/// endpoint (same trade-off as the Deezer cover lookup in `CoverArtService`).
enum LyricsService {
    private struct Entry: Decodable {
        let plainLyrics: String?
        let syncedLyrics: String?
        let instrumental: Bool?
    }

    private static let userAgent = "GramMusic (https://github.com/TheMalenia/grammusic)"

    /// The best available lyrics string for a track (synced LRC preferred), or nil.
    static func lyrics(title: String, performer: String, durationSeconds: Int) async -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let performer = performer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, performer.count >= 2 else { return nil }

        // 1. Exact match: /api/get needs title + artist + duration (±2s tolerance server-side).
        if let entry = await get(title: title, performer: performer, duration: durationSeconds),
           let best = best(of: entry) {
            return best
        }
        // 2. Looser fallback: /api/search returns candidates without a duration constraint.
        if let entry = await search(title: title, performer: performer),
           let best = best(of: entry) {
            return best
        }
        return nil
    }

    private static func best(of entry: Entry) -> String? {
        if entry.instrumental == true { return nil }
        if let synced = entry.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return synced
        }
        if let plain = entry.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plain
        }
        return nil
    }

    private static func get(title: String, performer: String, duration: Int) async -> Entry? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [
            .init(name: "track_name", value: title),
            .init(name: "artist_name", value: performer),
            .init(name: "duration", value: String(duration)),
        ]
        guard let data = await fetch(comps.url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private static func search(title: String, performer: String) async -> Entry? {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [
            .init(name: "track_name", value: title),
            .init(name: "artist_name", value: performer),
        ]
        guard let data = await fetch(comps.url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        // First candidate that actually carries lyrics (synced preferred).
        return entries.first { best(of: $0) != nil }
    }

    private static func fetch(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }
}

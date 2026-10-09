import Foundation

/// Looks up full-resolution album art from Deezer's public search API (free, keyless) by a
/// track's title + artist. Used to give crisp covers for tracks Telegram only has a small
/// thumbnail for (e.g. audio you haven't downloaded). A confident match needs both a title
/// and a performer — we skip the lookup otherwise to avoid pulling a wrong cover for
/// untagged/voice files. Results are best-effort: any failure returns nil so the caller can
/// fall back to Telegram's own cover.
///
/// Privacy note: this sends the track's title + artist to Deezer's public search endpoint.
enum CoverArtService {
    private struct SearchResponse: Decodable { let results: [Item] }
    private struct Item: Decodable {
        let artistName: String?
        let artworkUrl100: String?
    }

    /// A high-res cover (~1000px) for the track fetched from iTunes Search API.
    /// Returns `nil` for a genuine *no-match*. **Throws** on a transient failure so
    /// the caller can retry.
    static func artwork(title: String, performer: String) async throws -> Data? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let performer = performer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, performer.count >= 2 else { return nil }

        let term = "\(performer) \(title)"
        
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: term),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "1")
        ]
        guard let searchURL = comps.url else { return nil }
        
        let (data, response) = try await URLSession.shared.data(from: searchURL)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        guard let resp = try? JSONDecoder().decode(SearchResponse.self, from: data),
              let firstItem = resp.results.first,
              let artworkURLString = firstItem.artworkUrl100 else { return nil }

        // iTunes gives us a 100x100 URL by default. We replace it to get a 1000x1000 image.
        let highResURLString = artworkURLString.replacingOccurrences(of: "100x100bb.jpg", with: "1000x1000bb.jpg")
        guard let coverURL = URL(string: highResURLString) else { return nil }

        let (imageData, _) = try await URLSession.shared.data(from: coverURL)
        return imageData.isEmpty ? nil : imageData
    }

    /// Fetches a representative photo/cover for the artist from the iTunes Search API.
    /// Because iTunes does not provide direct artist portraits in its API, this searches for
    /// the artist's top album and returns its high-res cover art.
    static func artistPhoto(name: String) async throws -> Data? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2 else { return nil }

        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: name),
            .init(name: "entity", value: "album"),
            .init(name: "limit", value: "1")
        ]
        guard let searchURL = comps.url else { return nil }
        
        let (data, response) = try await URLSession.shared.data(from: searchURL)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        guard let resp = try? JSONDecoder().decode(SearchResponse.self, from: data),
              let artist = resp.results.first,
              // Guard against fuzzy matches by ensuring the result's artist name matches the query.
              let resultArtistName = artist.artistName,
              resultArtistName.localizedCaseInsensitiveCompare(name) == .orderedSame,
              let artworkURLString = artist.artworkUrl100 else { return nil }

        let highResURLString = artworkURLString.replacingOccurrences(of: "100x100bb.jpg", with: "1000x1000bb.jpg")
        guard let pictureURL = URL(string: highResURLString) else { return nil }

        let (imageData, _) = try await URLSession.shared.data(from: pictureURL)
        return imageData.isEmpty ? nil : imageData
    }
}

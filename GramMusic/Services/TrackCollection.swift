import Foundation

/// A snapshot of the source and query, independent of changes to the visible list.
typealias TrackCollectionLoader = @MainActor () async throws -> [AudioTrack]

enum TrackCollection {
    @MainActor
    static func load(fetchPage: (String) async throws -> MusicSearchPage) async throws -> [AudioTrack] {
        var tracks: [AudioTrack] = []
        var offset = ""
        var visited: Set<String> = [""]
        while true {
            try Task.checkCancellation()
            let page = try await fetchPage(offset)
            try Task.checkCancellation()
            tracks.append(contentsOf: page.tracks)
            guard !page.nextOffset.isEmpty, visited.insert(page.nextOffset).inserted else { break }
            offset = page.nextOffset
        }
        return AudioSearch.deduped(tracks)
    }
}

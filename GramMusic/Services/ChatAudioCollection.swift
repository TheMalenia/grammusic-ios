import Foundation

/// Walk the audio search independently of the visible list. Pages may overlap and may be
/// shorter than the requested limit, so only an empty/repeated page ends the traversal.
enum ChatAudioCollection {
    @MainActor
    static func load(
        fetchPage: (Int64) async throws -> [AudioTrack],
        progress: (Int) -> Void = { _ in },
        onPage: ([AudioTrack]) -> Void = { _ in }
    ) async throws -> [AudioTrack] {
        var tracks: [AudioTrack] = []
        var seen = Set<String>()
        var cursors: Set<Int64> = [0]
        var cursor: Int64 = 0
        while true {
            try Task.checkCancellation()
            let page = try await fetchPage(cursor)
            try Task.checkCancellation()
            guard !page.isEmpty else { break }
            let fresh = page.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { break }
            tracks.append(contentsOf: fresh)
            progress(tracks.count)
            onPage(fresh)
            guard let next = page.last?.messageId, cursors.insert(next).inserted else { break }
            cursor = next
        }
        return tracks
    }
}

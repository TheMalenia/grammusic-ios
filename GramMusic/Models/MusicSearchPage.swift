import Foundation

/// Only playable audio is exposed as tracks; bot articles/buttons never become fake songs.
struct MusicSearchPage: Sendable {
    var tracks: [AudioTrack]
    var nextOffset: String = ""
    var nonAudioResultCount: Int = 0

    init(tracks: [AudioTrack], nextOffset: String = "", nonAudioResultCount: Int = 0) {
        self.tracks = tracks
        self.nextOffset = nextOffset
        self.nonAudioResultCount = nonAudioResultCount
    }

    init(inlineResults: AppInlineQueryResults) {
        tracks = AudioSearch.deduped(inlineResults.results.compactMap(\.track))
        nextOffset = inlineResults.nextOffset
        nonAudioResultCount = inlineResults.results.filter { $0.track == nil }.count
    }
}

import Foundation

extension PlaylistService {
    /// Restore a removed local track at its previous position, preserving intervening edits.
    func restore(_ track: AudioTrack, to playlist: Playlist, at index: Int) {
        guard playlist.modelContext != nil, !playlist.isSmart, !playlist.contains(track) else { return }
        add(track, to: playlist)
        let position = max(0, min(index, playlist.tracks.count - 1))
        if position > 0 {
            move(in: playlist, from: IndexSet(integer: 0), to: position + 1)
        }
    }
}

import Foundation
import Observation

/// Reversible, account-owned exclusions. Audio and Telegram messages are never deleted.
@MainActor @Observable
final class HiddenTracksStore {
    private(set) var tracks: [AudioTrack]
    private(set) var ids: Set<String>
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: StorageKeys.hiddenTracks)
            .flatMap { try? JSONDecoder().decode([AudioTrack].self, from: $0) } ?? []
        let restored = AudioSearch.deduped(stored)
        tracks = restored
        ids = Set(restored.map(\.remoteUniqueId))
    }

    func hide(_ songs: [AudioTrack]) {
        for var song in songs where ids.insert(song.remoteUniqueId).inserted {
            song.artworkData = nil
            tracks.append(song)
        }
        persist()
    }

    func unhide(_ id: String) {
        unhide([id])
    }

    func unhide(_ restoredIDs: Set<String>) {
        guard !ids.isDisjoint(with: restoredIDs) else { return }
        ids.subtract(restoredIDs)
        tracks.removeAll { restoredIDs.contains($0.remoteUniqueId) }
        persist()
    }

    func clear() {
        ids.removeAll()
        tracks.removeAll()
        defaults.removeObject(forKey: StorageKeys.hiddenTracks)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(tracks) { defaults.set(data, forKey: StorageKeys.hiddenTracks) }
    }
}

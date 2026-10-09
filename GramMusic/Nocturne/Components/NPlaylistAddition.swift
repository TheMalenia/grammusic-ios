import Foundation
import Observation

/// Fetch the entire selection before changing local playlist membership.
@MainActor @Observable
final class NPlaylistAddition {
    private(set) var isAdding = false
    var error: String?

    func add(load: TrackCollectionLoader, commit: @MainActor ([AudioTrack]) async throws -> Void) async -> Bool {
        guard !isAdding else { return false }
        isAdding = true
        error = nil
        defer { isAdding = false }
        do {
            let tracks = AudioSearch.deduped(try await load())
            try Task.checkCancellation()
            guard !tracks.isEmpty else { throw TelegramError.backend("No songs remain in this selection.") }
            try await commit(tracks)
            return true
        } catch is CancellationError {
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

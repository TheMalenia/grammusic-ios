import SwiftUI
import Observation

@MainActor @Observable
final class NTrackSelection {
    private(set) var isSelecting = false
    private(set) var ids: Set<String> = []
    private(set) var includesUnloaded = false
    private(set) var excludedIDs: Set<String> = []

    func begin(_ track: AudioTrack) {
        isSelecting = true
        ids.insert(track.remoteUniqueId)
    }

    func toggle(_ track: AudioTrack) {
        if includesUnloaded {
            if excludedIDs.insert(track.remoteUniqueId).inserted { ids.remove(track.remoteUniqueId) }
            else { excludedIDs.remove(track.remoteUniqueId); ids.insert(track.remoteUniqueId) }
        } else if !ids.insert(track.remoteUniqueId).inserted { ids.remove(track.remoteUniqueId) }
    }

    func selectAll(_ tracks: [AudioTrack]) {
        includesUnloaded = true
        excludedIDs.removeAll()
        ids = Set(tracks.map(\.remoteUniqueId))
    }

    func cancel() {
        isSelecting = false
        includesUnloaded = false
        excludedIDs.removeAll()
        ids.removeAll()
    }

    func contains(_ track: AudioTrack) -> Bool {
        includesUnloaded ? !excludedIDs.contains(track.remoteUniqueId) : ids.contains(track.remoteUniqueId)
    }

    func containsHidden(in tracks: [AudioTrack], hiddenIDs: Set<String>) -> Bool {
        tracks.contains { contains($0) && hiddenIDs.contains($0.remoteUniqueId) }
    }

    var label: String {
        if includesUnloaded { return excludedIDs.isEmpty ? "All selected" : "All except \(excludedIDs.count)" }
        return "\(ids.count) selected"
    }

    func selected(from tracks: [AudioTrack]) -> [AudioTrack] {
        var seen = Set<String>()
        return tracks.filter { contains($0) && seen.insert($0.remoteUniqueId).inserted }
    }
}

private struct NTrackSelectionModifier: ViewModifier {
    let tracks: [AudioTrack]
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nMiniDockTop) private var dockTop
    @State private var selectionBottom: CGFloat = 0
    let selection: NTrackSelection
    var loadAll: TrackCollectionLoader?
    var destructiveTitle: String?
    var destructiveMessage: String?
    var destructiveIcon: String
    var requiresDestructiveConfirmation: Bool
    var onDestructive: (@MainActor ([AudioTrack]) async throws -> Void)?
    @State private var confirmDestructive = false
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var operationError: String?
    @State private var showPlaylists = false
    @State private var tracksToAdd: [AudioTrack] = []
    @State private var loaderToAdd: TrackCollectionLoader?

    private var hasSelection: Bool {
        selection.includesUnloaded || !selection.ids.isEmpty
    }

    private func addToPlaylist() {
        tracksToAdd = selection.selected(from: tracks)
        let excluded = selection.excludedIDs
        if selection.includesUnloaded, let loadAll {
            loaderToAdd = { try await loadAll().filter { !excluded.contains($0.remoteUniqueId) } }
        } else { loaderToAdd = nil }
        showPlaylists = true
    }

    private func closeSelection() {
        operation?.cancel()
        operationID = UUID()
        operation = nil
        confirmDestructive = false
        operationError = nil
        showPlaylists = false
        selection.cancel()
    }

    func body(content: Content) -> some View {
        content
            .environment(selection)
            .safeAreaInset(edge: .bottom) {
                if selection.isSelecting {
                    NTrackSelectionToolbar(
                        selection: selection, isWorking: operation != nil,
                        hasSelection: hasSelection,
                        destructiveTitle: onDestructive == nil ? nil : destructiveTitle,
                        destructiveIcon: destructiveIcon,
                        onSelectAll: { selection.selectAll(tracks) },
                        onAdd: addToPlaylist,
                        onDestructive: {
                            if requiresDestructiveConfirmation { confirmDestructive = true }
                            else { performDestructive() }
                        },
                        onClose: closeSelection
                    )
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .nGlass(RoundedRectangle(cornerRadius: 20), theme: theme, elevated: true)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    // Navigation destinations can retain the pre-playback safe area. Reserve
                    // only the overlap with the dock, so an already-inset screen has no extra gap.
                    .padding(.bottom, dockTop.map { max(0, selectionBottom - $0) } ?? 0)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                        selectionBottom = $0
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: selection.isSelecting)
            .sheet(isPresented: $showPlaylists) {
                NAddTracksToPlaylistSheet(tracks: tracksToAdd, loadAll: loaderToAdd) { selection.cancel() }
            }
            .sensoryFeedback(.selection, trigger: selection.ids)
            .confirmationDialog(destructiveTitle ?? "", isPresented: $confirmDestructive, titleVisibility: .visible) {
                Button(destructiveTitle ?? "", role: .destructive, action: performDestructive)
                Button("Cancel", role: .cancel) {}
            } message: { Text(destructiveMessage ?? "") }
            .alert("Couldn't update songs", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
                Button("OK", role: .cancel) { operationError = nil }
            } message: { Text(operationError ?? "") }
            .onDisappear { operation?.cancel(); selection.cancel() }
    }
    private func performDestructive() {
        guard operation == nil, let onDestructive else { return }
        let selected = selection.selected(from: tracks)
        let excluded = selection.excludedIDs
        let includeUnloaded = selection.includesUnloaded
        let id = UUID()
        operationID = id
        operation = Task {
            defer { if operationID == id { operation = nil } }
            do {
                let songs: [AudioTrack]
                if includeUnloaded, let loadAll { songs = try await loadAll().filter { !excluded.contains($0.remoteUniqueId) } }
                else { songs = selected }
                try Task.checkCancellation()
                try await onDestructive(AudioSearch.deduped(songs))
                guard operationID == id, !Task.isCancelled else { return }
                selection.cancel()
            } catch is CancellationError { }
            catch { if operationID == id { operationError = error.localizedDescription } }
        }
    }

}

extension View {
    func trackSelection(tracks: [AudioTrack], selection: NTrackSelection, loadAll: TrackCollectionLoader? = nil,
                        destructiveTitle: String? = nil, destructiveMessage: String? = nil,
                        destructiveIcon: String = "trash", requiresDestructiveConfirmation: Bool = true,
                        onDestructive: (@MainActor ([AudioTrack]) async throws -> Void)? = nil) -> some View {
        modifier(NTrackSelectionModifier(tracks: tracks, selection: selection, loadAll: loadAll,
                                        destructiveTitle: destructiveTitle, destructiveMessage: destructiveMessage,
                                        destructiveIcon: destructiveIcon, requiresDestructiveConfirmation: requiresDestructiveConfirmation,
                                        onDestructive: onDestructive))
    }
}

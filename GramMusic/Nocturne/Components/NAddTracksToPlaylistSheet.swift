import SwiftUI
import SwiftData

/// The bulk counterpart of the like-button picker, with the same playlist cards and destinations.
struct NAddTracksToPlaylistSheet: View {
    let tracks: [AudioTrack]
    var loadAll: TrackCollectionLoader? = nil
    let onAdded: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(TelegramService.self) private var telegram
    @Query(sort: \Playlist.createdAt, order: .reverse) private var playlists: [Playlist]
    @State private var name = ""
    @State private var addition = NPlaylistAddition()
    @State private var operation: Task<Void, Never>?
    @State private var destinationID: PersistentIdentifier?
    @State private var creating = false
    @FocusState private var nameFocused: Bool

    private var service: PlaylistService { PlaylistService(context: context) }
    private var eligible: [Playlist] { playlists.filter { !$0.isDownloads && !$0.isSearch }.sortedForLibrary }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    creationCard
                    destinationCards
                    if let error = addition.error {
                        Text(error).font(.subheadline).foregroundStyle(theme.text2)
                            .accessibilityLabel("Couldn't add to playlist. \(error)")
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 24)
            }
            .background(ScreenBackground())
            .navigationTitle(loadAll == nil ? "Add \(tracks.count) tracks" : "Add all tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(addition.isAdding ? "Cancel adding" : "Close", systemImage: "xmark") {
                        operation?.cancel()
                        nameFocused = false
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .interactiveDismissDisabled(addition.isAdding)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear { operation?.cancel() }
    }

    @ViewBuilder private var creationCard: some View {
        Group {
            if creating && addition.isAdding {
                Button {} label: { addingLabel.frame(maxWidth: .infinity, minHeight: 44) }
                    .disabled(true)
            } else {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accent.fillGradient)
                        .overlay { Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white) }
                        .frame(width: 44, height: 44)
                    TextField("New playlist name", text: $name)
                        .foregroundStyle(theme.text).focused($nameFocused)
                        .submitLabel(.done).onSubmit(createAndAdd)
                        .disabled(addition.isAdding)
                    Button("Create", action: createAndAdd)
                        .frame(minHeight: 44)
                        .fontWeight(.semibold).foregroundStyle(theme.accentColor)
                        .disabled(trimmedName.isEmpty || addition.isAdding)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.elev, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var destinationCards: some View {
        if !eligible.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Playlists").font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.text2).padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(Array(eligible.enumerated()), id: \.element.id) { index, playlist in
                        Button { add(to: playlist) } label: {
                            NPlaylistPickerRow(playlist: playlist,
                                               isAdding: destinationID == playlist.persistentModelID && addition.isAdding,
                                               addingSelection: true)
                        }
                        .buttonStyle(.plain).disabled(addition.isAdding)
                        if index < eligible.count - 1 {
                            Divider().overlay(theme.hairline).padding(.leading, 72)
                        }
                    }
                }
                .background(theme.elev, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var addingLabel: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Adding to playlist…").font(.subheadline)
        }
        .foregroundStyle(theme.accentColor)
        .accessibilityElement(children: .combine)
    }

    private func createAndAdd() {
        guard !trimmedName.isEmpty else { return }
        let title = trimmedName
        start(playlist: nil) { tracks in
            let playlist = service.create(name: title)
            telegram.markOpened(playlist.pinKey)
            service.add(tracks, to: playlist)
        }
    }

    private func add(to playlist: Playlist) {
        start(playlist: playlist) { tracks in
            if playlist.isProfile { try await telegram.addSelectionToProfile(tracks) }
            else { service.add(tracks, to: playlist) }
        }
    }

    private func start(playlist: Playlist?, commit: @escaping @MainActor ([AudioTrack]) async throws -> Void) {
        guard operation == nil else { return }
        nameFocused = false
        destinationID = playlist?.persistentModelID
        creating = playlist == nil
        let load = loadAll ?? { tracks }
        operation = Task {
            if await addition.add(load: load, commit: commit) {
                onAdded()
                dismiss()
            }
            operation = nil
        }
    }
}

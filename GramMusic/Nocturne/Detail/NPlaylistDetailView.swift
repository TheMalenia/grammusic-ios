import SwiftUI
import SwiftData

/// A playlist's tracks in Nocturne style (screens §7): hero artwork + stats, Play / Shuffle,
/// find-in-playlist, then an artwork-style track list. Reorder by long-press-dragging a row;
/// swipe to remove (native `List` affordances). Smart playlists (Favorites / Downloaded) are
/// read-only.
struct NPlaylistDetailView: View {
    @Bindable var playlist: Playlist

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(PlayerEngine.self) private var player
    @Environment(NActionFeedback.self) private var feedback: NActionFeedback?
    @Environment(TelegramService.self) private var telegram

    @State private var selection = NTrackSelection()
    @State private var editMode: EditMode = .inactive
    @State private var showSearch = false
    @State private var showAddSongs = false
    @State private var showEditPlaylist = false
    @State private var confirmClearSearch = false
    @State private var actionTarget: AudioTrack?

    private var service: PlaylistService { PlaylistService(context: context) }
    private var allTracks: [AudioTrack] { playlist.orderedTracks.map(\.audioTrack) }
    /// Profile Music is a smart playlist but is editable — its add/remove/reorder write back to
    /// the user's Telegram profile (via `TelegramService`) instead of the local `PlaylistService`.
    private var editable: Bool { !playlist.isSmart || playlist.isProfile }

    private var fullCollectionLoader: TrackCollectionLoader? {
        guard playlist.isProfile else { return nil }
        return { try await telegram.allOwnProfileAudio() }
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScreenBackground()

            LinearGradient(
                colors: [theme.accent.color.opacity(0.45), theme.accent.color.opacity(0.12), theme.bg.opacity(0)],
                startPoint: .top, endPoint: .bottom)
                .frame(height: 360).frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .top).allowsHitTesting(false)

            List {
                Section {
                    hero
                        .listRowInsets(EdgeInsets(top: 70, leading: 16, bottom: 12, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .moveDisabled(true)
                        .deleteDisabled(true)
                }

                Section {
                    tracksSection
                    
                    // Provide some breathing room at the bottom.
                    Color.clear.frame(height: telegram.isOfflineStable ? 64 : 24)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)

            topBar
        }
        .environment(\.editMode, $editMode)
        .trackSelection(tracks: allTracks, selection: selection, loadAll: fullCollectionLoader,
                        destructiveTitle: playlist.isDownloads ? nil : String(localized: "Remove from playlist"),
                        destructiveMessage: "Remove the selected songs from this playlist? Their audio files and Telegram messages are kept.",
                        onDestructive: { songs in
                            if playlist.isProfile { try await telegram.removeSelectionFromProfile(songs) }
                            else { service.removeTracks(songs, from: playlist) }
                        })
        .confirmationDialog("Clear Search playlist?", isPresented: $confirmClearSearch, titleVisibility: .visible) {
            Button("Clear all", role: .destructive) { service.clearSearchPlaylist(playlist) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears saved search listening history. New songs you listen to from search can still be saved while the setting is enabled.")
        }
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipe()      // restore edge-swipe-back (hidden bar disables it)
        .sheet(isPresented: $showAddSongs) { NAddSongsSheet(playlist: playlist) }
        .sheet(item: $actionTarget) { track in NTrackActionsSheet(track: track) }
        .sheet(isPresented: $showEditPlaylist) { NEditPlaylistSheet(playlist: playlist) }
        .navigationDestination(isPresented: $showSearch) {
            NSearchView(
                localScope: .init(title: playlist.name, tracks: allTracks, context: playlist.name, loadAll: fullCollectionLoader),
                isTab: true, embeddedInNavigation: true,
                onClose: { NScopedSearchTransition.setPresented(false, using: $showSearch) })
        }
    }

    // MARK: Tracks

    /// Split into `trackRows` / `trackRow(_:)` rather than one nested expression.
    ///
    /// Not cosmetic: as a single `@ViewBuilder` — a `ForEach` whose body carries two
    /// `swipeActions` closures, each with its own conditional content — this was the one
    /// expression in the app that made the type-checker give up under
    /// `SWIFT_STRICT_CONCURRENCY: complete` ("failed to produce diagnostic for expression").
    /// Breaking it up compiles cleanly and let the whole project move to `complete`.
    @ViewBuilder private var tracksSection: some View {
        if playlist.tracks.isEmpty {
            emptyState
                .listRowInsets(EdgeInsets(top: 32, leading: 24, bottom: 24, trailing: 24))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else {
            if editable {
                addMusicRow
            }
            trackRows
        }
    }

    private var trackRows: some View {
        // Spelled out rather than `editable ? moveTracks : nil` inline: the ternary over an
        // optional closure is ambiguous to the type-checker once this sits inside a `List`.
        var move: ((IndexSet, Int) -> Void)?
        if editable { move = { source, destination in moveTracks(from: source, to: destination) } }
        return ForEach(playlist.orderedTracks, id: \.id) { ref in
            trackRow(ref)
        }
        .onMove(perform: move)
    }

    private func trackRow(_ ref: TrackRef) -> some View {
        row(ref)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .moveDisabled(editMode != .active || selection.isSelecting)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if !selection.isSelecting {
                    if editable {
                        Button(role: .destructive) { removeTrack(ref) } label: {
                            Label(playlist.isProfile ? "Remove from Profile" : "Remove",
                                  systemImage: "trash")
                        }
                    }
                }
            }
            .swipeActions(edge: .leading) {
                if !selection.isSelecting {
                    Button { player.addToQueue(ref.audioTrack, feedback: feedback) } label: {
                        Label("Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                    }
                    .tint(theme.accentColor)
                }
            }
    }

    @ViewBuilder private var addMusicRow: some View {
        Button {
            showAddSongs = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(theme.accentColor)
                }
                .frame(width: 48, height: 48)

                Text(playlist.isProfile ? "Add to Your Profile" : "Add to this playlist")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.accentColor)

                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(NPressable(scale: 0.98))
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .moveDisabled(true)
        .deleteDisabled(true)
    }

    /// Remove a track — pushing the change to Telegram for Profile Music, else just locally.
    private func removeTrack(_ ref: TrackRef) {
        if playlist.isProfile {
            let track = ref.audioTrack
            Task { await telegram.removeFromProfile(track) }
        } else {
            let track = ref.audioTrack
            let position = playlist.orderedTracks.firstIndex(where: { $0 === ref }) ?? 0
            service.remove(ref, from: playlist)
            feedback?.show(String(localized: "Removed from playlist"), undo: { [weak playlist] in
                guard let playlist else { return }
                service.restore(track, to: playlist, at: position)
            })
        }
    }

    /// Reorder rows — pushing the new order to Telegram for Profile Music, else just locally.
    private func moveTracks(from source: IndexSet, to destination: Int) {
        if playlist.isProfile {
            Task { await telegram.moveProfileAudio(from: source, to: destination) }
        } else {
            service.move(in: playlist, from: source, to: destination)
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: playlist.symbolName)
                .font(.system(size: 34, weight: .medium)).foregroundStyle(theme.text3)
            Text(editable ? "This playlist is empty" : "Nothing here yet")
                .font(.display(18, .semibold)).foregroundStyle(theme.text)
            Text(playlist.isSearch
                 ? "Songs you listen to from search appear here when Save songs played from search is enabled."
                 : playlist.isProfile
                 ? "Add songs to show on your Telegram profile."
                 : editable
                 ? "Add songs from your chats, or swipe a track onto this playlist from anywhere."
                 : (playlist.isFavorites ? "Tap the heart on any track to add it here."
                                          : "Downloaded tracks show up here automatically."))
                .font(.system(size: 14)).foregroundStyle(theme.text2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if editable {
                Pill(title: "Add songs", systemImage: "plus", variant: .primary, size: .md) {
                    showAddSongs = true
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity).padding(28)
        .nocturneGlassCard(theme)
    }

    private func row(_ ref: TrackRef) -> some View {
        let t = ref.audioTrack
        return TrackRow(title: t.displayTitle,
                        subtitle: t.displaySubtitle,
                        seed: t.remoteUniqueId,
                        track: t,
                        isActive: player.current?.remoteUniqueId == ref.remoteUniqueId,
                        isPlaying: player.isPlaying,
                        downloaded: telegram.isDownloaded(t),
                        duration: telegram.isHidden(t) ? "Hidden" : t.formattedDuration,
                        onTap: { playFrom(ref) },
                        onMore: { actionTarget = t })
            .opacity(telegram.isHidden(t) ? 0.5 : 1)
    }

    // MARK: Hero

    /// "Download all" / "Stop (N)", the same control the chat screens carry.
    ///
    /// `isExplicitlyDownloading` — not `isDownloading` — for the count and the stop: the playing
    /// track and its lookahead are downloading too, and this button must never cancel those.
    private var downloadAllRow: some View {
        // Counted from the refs' ids, never from `allTracks`. This row re-renders while a download
        // progresses, and `allTracks` sorts the relationship and materialises an `AudioTrack` per
        // row — on a few-hundred-track playlist that is hundreds of SwiftData object reads per
        // frame. Set lookups on the ids give the same two numbers for nothing. The full tracks are
        // built only inside the action, where it happens once per tap.
        var pending = 0
        var remaining = 0
        for ref in playlist.tracks {
            let key = ref.remoteUniqueId
            if telegram.explicitDownloadIds.contains(key), telegram.downloadingIds.contains(key) { pending += 1 }
            if !telegram.downloadedIds.contains(key) { remaining += 1 }
        }
        return HStack {
            Spacer()
            Button {
                if pending > 0 { telegram.stopDownloads(allTracks) }
                else { telegram.downloadAll(allTracks) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: pending > 0 ? "stop.circle"
                          : (remaining == 0 ? "checkmark.circle.fill" : "arrow.down.circle"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(pending > 0 ? "Stop (\(pending))"
                         : (remaining == 0 ? "Downloaded" : "Download all"))
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1).fixedSize()
                }
                .foregroundStyle(remaining == 0 && pending == 0 ? theme.text2 : theme.accentColor)
            }
            .buttonStyle(NPressable(scale: 0.95))
            .disabled(remaining == 0 && pending == 0)
            .accessibilityLabel(pending > 0 ? "Stop downloading" : "Download all")
            Spacer()
        }
    }

    private var hero: some View {
        VStack(spacing: 16) {
            artwork
                .shadow(color: theme.shadow.opacity(0.55), radius: 22, y: 12)

            VStack(spacing: 4) {
                Text(playlist.name).font(.display(30, .bold)).tracking(-0.5)
                    .foregroundStyle(theme.text).multilineTextAlignment(.center).lineLimit(2)
                Text(stats).font(.system(size: 14)).foregroundStyle(theme.text2)
            }

            HStack(spacing: 12) {
                Pill(title: "Play", systemImage: "play.fill", variant: .primary, fullWidth: true) {
                    playlist.playCount += 1
                    player.isShuffle = false
                    player.play(tracks: allTracks, context: playlist.name)
                }
                Pill(title: "Shuffle", systemImage: "shuffle", variant: .light, fullWidth: true) {
                    playlist.playCount += 1
                    player.shufflePlay(tracks: allTracks, context: playlist.name)
                }
            }
            .disabled(playlist.tracks.isEmpty)
            .opacity(playlist.tracks.isEmpty ? 0.5 : 1)

            if !playlist.tracks.isEmpty { downloadAllRow }

            if playlist.tracks.count > 4 {
                SearchBarButton(prompt: "Find in \(playlist.name)") {
                    NScopedSearchTransition.setPresented(true, using: $showSearch)
                }
            }

            if editable && playlist.tracks.count > 1 {
                Text("Hold a song to select · tap Reorder to arrange songs.")
                    .font(.system(size: 12.5)).foregroundStyle(theme.text3)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var artwork: some View {
        if playlist.isSmart {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(theme.accent.fillGradient)
                .overlay {
                    Image(systemName: playlist.symbolName)
                        .font(.system(size: 196 * 0.32, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 196, height: 196)
        } else if let coverData = playlist.coverImageData, let ui = UIImage(data: coverData) {
            Image(uiImage: ui).resizable().scaledToFill()
                .frame(width: 196, height: 196)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                }
        } else {
            PlaylistArtwork(playlist: playlist, size: 196)
        }
    }

    private var stats: String {
        let count = playlist.trackCount
        let kind = playlist.isFavorites ? "liked" : (playlist.isProfile ? "profile" : (playlist.isSearch ? "search" : "downloaded"))
        let prefix = playlist.isSmart ? "Smart · \(kind) · " : ""
        return "\(prefix)\(count) track\(count == 1 ? "" : "s") · \(playlist.formattedDuration)"
    }

    private var deletedTracksCount: Int {
        playlist.tracks.filter { telegram.isUnavailableOnTelegram(remoteUniqueId: $0.remoteUniqueId) }.count
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(width: 38, height: 38)
                    .nocturneGlass(Circle(), theme: theme)
                    .frame(width: 44, height: 44)        // ≥44pt tap target around the 38pt glass
                    .contentShape(Circle())
            }
            .buttonStyle(NPressable(scale: 0.9))
            .accessibilityLabel("Back")

            Spacer()

            if playlist.isSearch {
                Menu("Search playlist options", systemImage: "ellipsis") {
                    Button("Clear all", systemImage: "trash", role: .destructive) { confirmClearSearch = true }
                        .disabled(playlist.tracks.isEmpty)
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(theme.text)
                .frame(width: 44, height: 44)
            }

            if editable {
                Button(editMode == .active ? "Done" : "Reorder") {
                    selection.cancel()
                    editMode = editMode == .active ? .inactive : .active
                }
                .foregroundStyle(theme.accentColor)
            }

            if editable && !playlist.isProfile {
                if deletedTracksCount > 0 {
                    Button {
                        let count = service.removeUnavailableTracks(from: playlist, unavailableIds: telegram.unavailableTrackIds)
                        if count > 0 {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                    } label: {
                        Image(systemName: "trash.slash")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xFF453A))
                            .frame(width: 38, height: 38)
                            .nocturneGlass(Circle(), theme: theme)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(NPressable(scale: 0.9))
                    .accessibilityLabel("Remove \(deletedTracksCount) deleted track\(deletedTracksCount == 1 ? "" : "s")")
                }

                Button { showEditPlaylist = true } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .frame(width: 38, height: 38)
                        .nocturneGlass(Circle(), theme: theme)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(NPressable(scale: 0.9))
                .accessibilityLabel("Edit Playlist")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func playFrom(_ ref: TrackRef) {
        guard !telegram.isHidden(ref.audioTrack) else { return }
        playlist.playCount += 1
        let ordered = playlist.orderedTracks.map(\.audioTrack)
        let start = playlist.orderedTracks.firstIndex { $0.remoteUniqueId == ref.remoteUniqueId } ?? 0
        player.play(tracks: ordered, startAt: start, context: playlist.name)
    }
}

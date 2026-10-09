import SwiftUI
import SwiftData
import PhotosUI

/// Small playlist cover used in lists/sheets: smart playlists get the accent-gradient +
/// glyph (our cover, never a track's art); others use the first track's art or the seed.
struct NPlaylistCover: View {
    @Environment(\.theme) private var theme
    let playlist: Playlist
    var size: CGFloat = 44

    var body: some View {
        if playlist.isSmart {
            RoundedRectangle(cornerRadius: max(8, size * 0.18), style: .continuous)
                .fill(theme.accent.fillGradient)
                .overlay { Image(systemName: playlist.symbolName)
                    .font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white) }
                .frame(width: size, height: size)
        } else if let coverData = playlist.coverImageData, let ui = UIImage(data: coverData) {
            Image(uiImage: ui).resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: max(8, size * 0.18), style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: max(8, size * 0.18), style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                }
        } else if let first = playlist.orderedTracks.first?.audioTrack {
            TrackArtwork(track: first, size: size, kind: .playlist)
        } else {
            Artwork(seed: playlist.name, size: size, kind: .playlist)
        }
    }
}

/// "Name your playlist" modal: centered cover tile with camera badge, a big borderless name
/// field, Cancel / Create in the nav bar. Tapping the tile opens a PhotosPicker.
struct NNewPlaylistSheet: View {
    var onCreate: (String, Data?) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedItem: PhotosPickerItem?
    @State private var coverData: Data?
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let cover = coverData
        return NavigationStack {
            VStack(spacing: 28) {
                PhotosPicker(selection: $selectedItem, matching: .images) {
                    NCoverPickerTile(coverData: cover, fallbackSeed: nil)
                }
                .buttonStyle(.plain)
                .padding(.top, 24)
                .onChange(of: selectedItem) { _, item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self) {
                            // Compress to JPEG to keep SwiftData storage lean.
                            if let ui = UIImage(data: data),
                               let jpeg = ui.jpegData(compressionQuality: 0.82) {
                                coverData = jpeg
                            } else {
                                coverData = data
                            }
                        }
                    }
                }

                TextField("Playlist name", text: $name)
                    .font(.title2.bold())
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(create)

                Spacer()
            }
            .padding(24)
            .background(ScreenBackground())
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create).fontWeight(.semibold).disabled(trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed, coverData)
        dismiss()
    }
}

/// Add a track to an existing playlist, or create one on the spot (screens §12). Playlists
/// that already contain the track show a filled check and are disabled; Downloads is
/// auto-managed so it's excluded. (Replaces the old `AddToPlaylistView`.)
struct NAddToPlaylistSheet: View {
    let track: AudioTrack

    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(TelegramService.self) private var telegram
    @Query(sort: \Playlist.createdAt, order: .reverse) private var playlists: [Playlist]

    @State private var newName = ""
    /// True while the Profile Music write is in flight. Profile Music is the one row here whose
    /// membership lives on Telegram, so it can't flip instantly — the row shows the filling ring
    /// until the server confirms and `syncProfileAudio()` reconciles the mirror.
    @State private var profileWriteInFlight = false
    @FocusState private var nameFocused: Bool

    private var service: PlaylistService { PlaylistService(context: context) }
    private var eligible: [Playlist] { playlists.filter { !$0.isDownloads && !$0.isSearch }.sortedForLibrary }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        TrackArtwork(track: track, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.displayTitle).font(.headline).foregroundStyle(theme.text).lineLimit(2)
                            Text(track.displaySubtitle).font(.subheadline).foregroundStyle(theme.text2).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 4)

                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.accent.fillGradient)
                            .overlay { Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white) }
                            .frame(width: 44, height: 44)
                        TextField("New playlist name", text: $newName)
                            .foregroundStyle(theme.text)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit(createAndAdd)
                        Button("Create", action: createAndAdd)
                            .frame(minHeight: 44)
                            .fontWeight(.semibold)
                            .foregroundStyle(theme.accentColor)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(theme.elev, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if !eligible.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Playlists")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(theme.text2)
                                .padding(.leading, 4)
                            
                            VStack(spacing: 0) {
                                ForEach(Array(eligible.enumerated()), id: \.element.id) { index, playlist in
                                    let added = playlist.contains(track)
                                    Button {
                                        if playlist.isProfile { toggleProfile(added: added) }
                                        else if added { remove(track, from: playlist) }
                                        else { service.add(track, to: playlist) }
                                    } label: {
                                        NPlaylistPickerRow(playlist: playlist, isAdded: added,
                                                           isAdding: playlist.isProfile && profileWriteInFlight)
                                    }
                                    .buttonStyle(.plain)
                                    
                                    if index < eligible.count - 1 {
                                        Divider().overlay(theme.hairline)
                                            .padding(.leading, 72)
                                    }
                                }
                            }
                            .background(theme.elev, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(ScreenBackground())
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            // The Profile Music row talks to Telegram, so it can fail (offline, flood-wait) —
            // without this the row would just refuse to tick with no explanation.
            .playbackErrorBanner()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func createAndAdd() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let playlist = service.create(name: trimmed)
        telegram.markOpened(playlist.pinKey)
        service.add(track, to: playlist)
        newName = ""
        nameFocused = false
    }

    /// Profile Music is a *mirror* of the user's Telegram profile, not a local list — its
    /// membership has to be written to Telegram and re-synced. Adding it through
    /// `PlaylistService.add` like every other playlist only ticked the row locally: the song never
    /// reached the profile, and the next `syncProfileAudio()` (which reconciles from the server)
    /// quietly reconciled it away again.
    private func toggleProfile(added: Bool) {
        guard !profileWriteInFlight else { return }
        profileWriteInFlight = true
        Task {
            if added { await telegram.removeFromProfile(track) }
            else { await telegram.addToProfile(track) }
            withAnimation(.snappy) { profileWriteInFlight = false }
        }
    }

    private func remove(_ track: AudioTrack, from playlist: Playlist) {
        guard let ref = playlist.orderedTracks.first(where: { $0.remoteUniqueId == track.remoteUniqueId }) else { return }
        service.remove(ref, from: playlist)
    }
}

/// Search your chats' audio and add tracks directly to a specific playlist (the empty-state
/// "Add songs" flow). Tapping a result toggles its membership; a check marks tracks already in.
struct NAddSongsSheet: View {
    @Bindable var playlist: Playlist

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(TelegramService.self) private var telegram

    @State private var query = ""
    @State private var results: [AudioTrack] = []
    /// `remoteUniqueId`s whose add-to-Profile write is in flight, so the row shows the filling
    /// ring the instant it's tapped instead of waiting two network round-trips for the checkmark.
    @State private var pending: Set<String> = []
    /// A lookup is in flight — otherwise the gap between the last keystroke and the answer
    /// renders "No results", so every search looks like it failed before it succeeded.
    @State private var searching = false
    @FocusState private var focused: Bool

    private var service: PlaylistService { PlaylistService(context: context) }
    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    /// When the user hasn't typed yet we suggest something to add — for now their recently
    /// played tracks (a simple stand-in we can later make algorithmic). Once they search, we
    /// show live chat results instead.
    private var suggesting: Bool { trimmed.isEmpty }
    private var displayed: [AudioTrack] {
        suggesting ? AudioSearch.deduped(telegram.recentlyPlayed) : results
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                SearchField(text: $query, prompt: "Search songs & artists")
                    .focused($focused)

                if displayed.isEmpty {
                    Spacer()
                    if searching {
                        ProgressView().tint(theme.accentColor)
                    } else {
                        Text(suggesting ? "Search your chats to add songs."
                                        : "No results for “\(trimmed)”.")
                            .font(.system(size: 15)).foregroundStyle(theme.text2)
                    }
                    Spacer()
                } else {
                    List {
                        if suggesting {
                            Text("Recently played")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.text2)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        ForEach(displayed) { t in
                            let added = playlist.contains(t)
                            let state: AddBadgeState = added ? .added
                                : (pending.contains(t.remoteUniqueId) ? .adding : .idle)
                            Button {
                                if added { remove(t) } else { add(t) }
                            } label: {
                                HStack(spacing: 12) {
                                    TrackArtwork(track: t, size: 46)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.displayTitle).font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(theme.text).lineLimit(1)
                                        Text(t.displaySubtitle).font(.system(size: 13.5))
                                            .foregroundStyle(theme.text2).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    AddBadge(state: state, size: 24)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(theme.elev)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.immediately)
                }
            }
            .padding(.horizontal, 16).padding(.top, 12)
            .background(ScreenBackground())
            .navigationTitle("Add to \(playlist.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .playbackErrorBanner()
            .task(id: trimmed) { await run() }
        }
        .presentationDetents([.large])
    }

    private func run() async {
        guard !trimmed.isEmpty else { results = []; searching = false; return }
        searching = true
        try? await Task.sleep(for: .milliseconds(280))
        if Task.isCancelled { return }
        let term = trimmed
        let found = (try? await telegram.searchAudio(term)) ?? []
        if Task.isCancelled || term != trimmed { return }
        results = found
        searching = false
    }

    /// Profile Music writes to the user's Telegram profile; every other playlist is local.
    private func add(_ track: AudioTrack) {
        if playlist.isProfile {
            let key = track.remoteUniqueId
            withAnimation(.snappy) { _ = pending.insert(key) }   // instant filling-ring feedback
            Task {
                await telegram.addToProfile(track)               // resolves once Telegram confirms
                withAnimation(.snappy) { _ = pending.remove(key) }
            }
        } else {
            service.add(track, to: playlist)
        }
    }

    private func remove(_ track: AudioTrack) {
        if playlist.isProfile {
            Task { await telegram.removeFromProfile(track) }
            return
        }
        guard let ref = playlist.orderedTracks.first(where: { $0.remoteUniqueId == track.remoteUniqueId }) else { return }
        service.remove(ref, from: playlist)
    }
}

/// The three states of the trailing "add" affordance in the add-songs list.
enum AddBadgeState { case idle, adding, added }

/// A tiny add-status accessory: a plus when idle, a circle that fills clockwise (like a clock
/// hand sweeping) while the add is in flight, then a filled disc with a checkmark springing in at
/// its center once it lands. Gives instant feedback so a slow network add never feels frozen.
struct AddBadge: View {
    @Environment(\.theme) private var theme
    var state: AddBadgeState
    var size: CGFloat = 24

    @State private var fill: CGFloat = 0

    private var lineWidth: CGFloat { max(2, size * 0.1) }

    var body: some View {
        ZStack {
            switch state {
            case .idle:
                Image(systemName: "plus.circle")
                    .font(.system(size: size, weight: .regular))
                    .foregroundStyle(theme.text3)

            case .adding:
                ZStack {
                    Circle().stroke(theme.accentColor.opacity(0.22), lineWidth: lineWidth)
                    Circle()
                        .trim(from: 0, to: fill)
                        .stroke(theme.accentColor,
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))   // start the sweep at 12 o'clock
                }
                .frame(width: size, height: size)
                .onAppear {
                    fill = 0
                    // Sweep to nearly-full, then hold there until the network confirms — so the ring
                    // is clearly "working" without claiming it's done before Telegram says so.
                    withAnimation(.easeInOut(duration: 0.8)) { fill = 0.9 }
                }

            case .added:
                ZStack {
                    Circle().fill(theme.accentColor)
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.52, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: state)
    }
}


/// The tappable cover tile inside a `PhotosPicker`.
///
/// A standalone `View` taking only `Sendable` values, because `PhotosPicker`'s label closure is
/// `@Sendable`: anything that reads the enclosing view's state from inside it (its `theme`, its
/// `@State`) is a main-actor access from a nonisolated context, which is an error under the Swift 6
/// language mode. Reading `theme` from the environment *here* keeps the styling without the capture.
struct NCoverPickerTile: View {
    @Environment(\.theme) private var theme
    let coverData: Data?
    /// Seed for the generated artwork when there is no cover. `nil` uses the generic music glyph.
    let fallbackSeed: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let coverData, let ui = UIImage(data: coverData) {
                Image(uiImage: ui).resizable().scaledToFill()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    }
            } else if let fallbackSeed {
                Artwork(seed: fallbackSeed, size: 120, kind: .playlist)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.accent.fillGradient)
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                    .frame(width: 120, height: 120)
            }
            Circle()
                .fill(theme.elev)
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                }
                .overlay(Circle().strokeBorder(theme.bg, lineWidth: 2))
                .offset(x: 4, y: 4)
        }
        .shadow(color: theme.accentColor.opacity(0.45), radius: 18, y: 8)
    }
}

import SwiftUI
import SwiftData

/// Home (screens §3): greeting, Recently played,
/// New in your chats, Playlists, Your artists.
struct NHomeView: View {
    var onSearch: () -> Void = {}
    @Environment(\.theme) private var theme
    @Environment(TelegramService.self) private var telegram
    @Environment(PlayerEngine.self) private var player
    @Environment(ImportStore.self) private var importStore
    @Query private var playlists: [Playlist]

    @State private var newTracks: [AudioTrack] = Self.loadCachedNewSync()
    @State private var loadingNew = false
    @State private var showImport = false
    @State private var showRecent = false
    @State private var showNewTracks = false

    private var sortedPlaylists: [Playlist] { playlists.sortedByPlays }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 12) {
                        header
                        SearchBarButton(prompt: "Search music", action: onSearch)
                            .accessibilityIdentifier("home.search")
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        shelves
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .nMiniPlayerClearance(player.current != nil, offline: telegram.isOfflineStable, base: 24)
            }
            .background(ScreenBackground())
            .modifier(NScrollDockViewport())
            .navigationBarHidden(true)
            .nMusicDestinations()
            .task(id: newInTrigger) { await loadNew() }
            .sheet(isPresented: $showImport) { NImportChatsView(store: importStore) { showImport = false } }
            .navigationDestination(isPresented: $showRecent) {
                NTrackShelfView(title: "Recently played", tracks: telegram.recentlyPlayed)
            }
            .navigationDestination(isPresented: $showNewTracks) {
                NTrackShelfView(title: "New in your chats", tracks: newTracks)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(greeting).font(.display(33)).tracking(-0.6).foregroundStyle(theme.text)
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusLabel)
                    .font(.system(size: 13)).foregroundStyle(theme.text2)
            }
            .animation(.default, value: statusLabel)
        }
        .padding(.top, 16)
    }

    /// Reflects real connection state, and also app-level "Updating…" while chats load, so the
    /// indicator actually moves instead of sitting on a static "Synced".
    private var statusLabel: String {
        if let label = telegram.connectionState.label { return label }   // network: connecting/updating/offline
        return telegram.isLoadingChats ? "Updating…" : "Synced"
    }

    private var statusColor: Color {
        telegram.connectionState == .ready && !telegram.isLoadingChats ? theme.accentColor : theme.text3
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }


    // MARK: Shelves

    @ViewBuilder private var shelves: some View {
        if !telegram.recentlyPlayed.isEmpty {
            shelf("Recently played", actionLabel: "See all", action: { showRecent = true }) {
                ForEach(Array(telegram.recentlyPlayed.prefix(8).enumerated()), id: \.element.id) { i, track in
                    Button {
                        player.play(tracks: telegram.recentlyPlayed, startAt: i, context: "Recently Played")
                    } label: {
                        NShelfCard(seed: track.remoteUniqueId, title: track.displayTitle,
                                   subtitle: track.displaySubtitle, track: track)
                    }.buttonStyle(NPressable(scale: 0.96))
                }
            }
            .animation(.default, value: telegram.recentlyPlayed)
        }
        // Only worth a shelf once there's a real "rotation" — at least 5 repeat-played tracks.
        let onRepeat = telegram.topTracks()
        if onRepeat.count >= 5 {
            shelf("On repeat") {
                ForEach(Array(onRepeat.enumerated()), id: \.element.id) { i, track in
                    Button {
                        player.play(tracks: onRepeat, startAt: i, context: "On Repeat")
                    } label: {
                        NShelfCard(seed: track.remoteUniqueId, title: track.displayTitle,
                                   subtitle: track.displaySubtitle, track: track)
                    }.buttonStyle(NPressable(scale: 0.96))
                }
            }
            .animation(.default, value: onRepeat)
        }
        lastChats
        newInChats

        if !sortedPlaylists.isEmpty {
            shelf("Playlists") {
                ForEach(sortedPlaylists) { playlist in
                    NavigationLink(value: playlist) {
                        NShelfCard(seed: playlist.name, title: playlist.name,
                                   subtitle: "\(playlist.trackCount) tracks",
                                   playlist: playlist.isSmart ? nil : playlist,
                                   smart: playlist.isSmart, smartSymbol: playlist.symbolName)
                    }.buttonStyle(NPressable(scale: 0.96))
                }
            }
        }
        if !telegram.sortedFollowedArtists.isEmpty {
            shelf("Your artists") {
                ForEach(telegram.sortedFollowedArtists, id: \.self) { name in
                    NavigationLink(value: Artist(name: name)) {
                        VStack(spacing: 8) {
                            NArtistAvatar(name: name, size: 120)
                            Text(name).font(.system(size: 13)).foregroundStyle(theme.text2).lineLimit(1).frame(width: 120)
                        }
                    }.buttonStyle(NPressable(scale: 0.96))
                }
            }
        }
        if !telegram.userProfiles.isEmpty {
            shelf("Profiles") {
                ForEach(telegram.userProfiles) { profile in
                    NavigationLink(value: profile) {
                        NShelfCard(seed: profile.userName, title: profile.title,
                                   subtitle: "\(profile.trackCount) tracks",
                                   profile: profile)
                    }.buttonStyle(NPressable(scale: 0.96))
                }
            }
        }
        if telegram.recentlyPlayed.isEmpty && sortedPlaylists.isEmpty && telegram.userProfiles.isEmpty {
            emptyCard
        }
    }

    private func shelf<Content: View>(_ title: String, actionLabel: String? = nil,
                                      action: (() -> Void)? = nil, loading: Bool = false,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: title, actionLabel: actionLabel, action: action, loading: loading)
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy so long shelves (New in your chats can be up to 100 cards) only build and
                // resolve artwork for what's actually scrolled into view.
                LazyHStack(alignment: .top, spacing: 14) { content() }
            }
        }
    }

    /// The imported, audio-bearing chats. `telegram.chats` holds up to 1000 entries and this
    /// predicate was evaluated three separate times per body pass — once here, once for
    /// "Last chats", and once more inside `newInTrigger`, which is the `.task(id:)` key and so
    /// runs on *every* body evaluation.
    private var importedAudioChats: [TelegramChat] {
        telegram.chats.filter { importStore.isImported($0.id) && ($0.audioCount ?? 0) > 0 }
    }

    // "New in your chats" — the newest audio across the imported chats (merged globally newest-first,
    // deduped by stable id), up to the last 100 songs.
    @ViewBuilder private var newInChats: some View {
        let importedChats = importedAudioChats
        if !newTracks.isEmpty {
            // Shows the cached previous version instantly; a spinner by the title signals a
            // background refresh.
            shelf("New in your chats", actionLabel: "See all", action: { showNewTracks = true }, loading: loadingNew) {
                ForEach(Array(newTracks.prefix(8).enumerated()), id: \.element.id) { i, t in
                    Button { player.play(tracks: newTracks, startAt: i, context: "New in your chats") } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            TrackArtwork(track: t, size: 150)
                            Text(t.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text).lineLimit(1)
                            Text(t.displaySubtitle).font(.caption).foregroundStyle(theme.text2).lineLimit(1)
                        }
                        .frame(width: 150)
                    }
                    .buttonStyle(NPressable(scale: 0.96))
                }
            }
        } else if importedChats.isEmpty, !telegram.isInitialDataReady, let error = telegram.initialSyncError {
            // The launch sync failed. This state used to be unreachable *in the UI* — the error was
            // written to the service and read by nothing — so a failed launch showed the skeleton
            // below forever, with no explanation and no way to retry.
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "New in your chats")
                VStack(spacing: 12) {
                    Text(error)
                        .font(.system(size: 14)).foregroundStyle(theme.text2)
                        .multilineTextAlignment(.center)
                    Pill(title: "Try again", systemImage: "arrow.clockwise", variant: .primary, size: .sm) {
                        Task { await telegram.retryInitialSync() }
                    }
                }
                .frame(maxWidth: .infinity).padding(24).nocturneGlassCard(theme)
            }
        } else if importedChats.isEmpty && (telegram.isLoadingChats || !telegram.isInitialDataReady) {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "New in your chats", loading: true)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(0..<3, id: \.self) { _ in
                            NPulsingSkeleton()
                        }
                    }
                }
            }
        } else if importedChats.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "New in your chats")
                VStack(spacing: 12) {
                    Text("Import a Telegram chat to start listening.")
                        .font(.system(size: 14)).foregroundStyle(theme.text2)
                    Pill(title: "Manage chats", systemImage: "plus", variant: .primary, size: .sm) { showImport = true }
                }
                .frame(maxWidth: .infinity).padding(24).nocturneGlassCard(theme)
            }
        } else if loadingNew {
            // First-ever load with no cache yet.
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "New in your chats", loading: true)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(0..<3, id: \.self) { _ in
                            NPulsingSkeleton()
                        }
                    }
                }
            }
        }
    }
    
    // "Last chats" — the user's audio-bearing chats, sorted by most recent audio date.
    @ViewBuilder private var lastChats: some View {
        let importedChats = importedAudioChats
        let sortedChats = importedChats.sorted {
            ($0.lastAudioDate ?? .distantPast) > ($1.lastAudioDate ?? .distantPast)
        }
        
        if !sortedChats.isEmpty {
            shelf("Last chats", actionLabel: "Manage", action: { showImport = true }) {
                ForEach(Array(sortedChats.prefix(15))) { chat in
                    NavigationLink(value: chat) {
                        VStack(alignment: .center, spacing: 8) {
                            NChatAvatar(chat: chat, size: 84)
                                .shadow(color: theme.shadow.opacity(0.3), radius: 8, y: 4)
                            Text(chat.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                                .frame(width: 84)
                        }
                    }
                    .buttonStyle(NPressable(scale: 0.96))
                }
            }
        }
    }

    /// Re-fetch when the imported set changes *or* when chats finish loading after launch
    /// (`importedIds` alone is stable across launches, so the launch refresh would otherwise
    /// never retry once the backend becomes ready).
    private var newInTrigger: String {
        // Hash rather than build-and-join N strings: this runs on every body pass.
        var hasher = Hasher()
        for chat in importedAudioChats { hasher.combine(chat.id) }
        hasher.combine(importStore.removedChatIds.sorted())
        return String(hasher.finalize())
    }

    private func loadNew() async {
        // Show the cached previous version immediately so the shelf isn't blank while we refresh.
        if newTracks.isEmpty { newTracks = await Self.loadCachedNew() }
        loadingNew = true
        defer { loadingNew = false }
        // Pull the latest audio from each imported chat concurrently (newest-first per chat, up to ~50 each).
        // Capped at 15 chats to bound the refresh; the shelf already shows the cached set meanwhile.
        let chats = Array(telegram.chats.filter { importStore.isChatImported($0.id) && ($0.audioCount ?? 0) > 0 }.prefix(15))
        guard !chats.isEmpty else { return }
        
        let collected = await withTaskGroup(of: [AudioTrack].self) { group in
            for chat in chats {
                group.addTask { [telegram] in
                    (try? await telegram.audioMessages(in: chat.id)) ?? []
                }
            }
            var all: [AudioTrack] = []
            for await tracks in group {
                all.append(contentsOf: tracks.prefix(50))
            }
            return all
        }
        // Merge into ONE globally newest-first list — so "New" means new, not "the first few from
        // the first chat". Dedup by stable id (a title can be shared by distinct songs / be blank),
        // keeping the most recent occurrence. A rolling feed of up to the last 100 songs.
        var seen = Set<String>()
        let fresh = collected
            .sorted { ($0.date ?? 0) > ($1.date ?? 0) }
            .filter { seen.insert($0.remoteUniqueId).inserted }
            .prefix(100)
            .map { $0 }
        // Only replace the shelf when the refresh actually found something. At launch the backend
        // often isn't ready yet (no chats loaded), so `collected` is empty — keep the cached set on
        // screen instead of blanking it (and wiping the cache).
        guard !fresh.isEmpty else { return }
        newTracks = fresh
        Self.saveCachedNew(fresh)
    }

    // MARK: New-in-chats cache (last fetched set, shown instantly on next open)

    nonisolated private static let newCacheKey = "n_newInChats"

    nonisolated private static func loadCachedNewSync() -> [AudioTrack] {
        guard let data = UserDefaults.standard.data(forKey: newCacheKey) else { return [] }
        return (try? JSONDecoder().decode([AudioTrack].self, from: data)) ?? []
    }

    private static func loadCachedNew() async -> [AudioTrack] {
        guard let data = UserDefaults.standard.data(forKey: newCacheKey) else { return [] }
        return await Task.detached(priority: .userInitiated) {
            (try? JSONDecoder().decode([AudioTrack].self, from: data)) ?? []
        }.value
    }

    private static func saveCachedNew(_ tracks: [AudioTrack]) {
        Task.detached(priority: .background) {
            // Drop the inline minithumbnail to keep the cache small — covers re-resolve via TrackArtwork.
            let slim = tracks.map { $0.withArtwork(nil) }
            if let data = try? JSONEncoder().encode(slim) {
                UserDefaults.standard.set(data, forKey: newCacheKey)
            }
        }
    }

    private var emptyCard: some View {
        let offline = telegram.connectionState == .waitingForNetwork
        return VStack(spacing: 12) {
            Image(systemName: offline ? "wifi.slash" : "music.note")
                .font(.system(size: 26)).foregroundStyle(theme.text3)
            Text(offline ? "You're offline" : "Nothing yet")
                .font(.display(18, .semibold)).foregroundStyle(theme.text)
            Text(offline
                 ? "Downloaded music still plays offline. Reconnect to load your chats and playlists."
                 : "Play something from a chat, or like a track to start your library.")
                .font(.system(size: 14)).foregroundStyle(theme.text2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(28)
        .nocturneGlassCard(theme)
    }

}

/// Square shelf card (Home shelves). `smart` renders an accent-gradient cover with a glyph.
struct NShelfCard: View {
    @Environment(\.theme) private var theme
    var seed: String
    var title: String
    var subtitle: String
    var data: Data? = nil
    /// When set, the card resolves the track's real cover on demand (recently played, etc.).
    var track: AudioTrack? = nil
    /// When set, the card resolves the playlist's hi-res cover on demand (Made-for-you shelf).
    var playlist: Playlist? = nil
    /// When set, the card resolves the profile's hi-res cover on demand (Profiles shelf).
    var profile: UserProfilePlaylist? = nil
    var smart: Bool = false
    var smartSymbol: String = "heart.fill"
    var size: CGFloat = 134

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if smart {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.accent.fillGradient)
                        .overlay { Image(systemName: smartSymbol).font(.system(size: size * 0.3)).foregroundStyle(.white) }
                        .frame(width: size, height: size)
                } else if let track {
                    TrackArtwork(track: track, size: size)
                } else if let playlist {
                    PlaylistArtwork(playlist: playlist, size: size)
                } else if let profile {
                    NProfileAvatar(profile: profile, size: size)
                } else {
                    Artwork(data: data, seed: seed, size: size)
                }
            }
            .shadow(color: theme.shadow.opacity(0.5), radius: 10, y: 6)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(theme.text2).lineLimit(1)
        }
        .frame(width: size)
    }
}

/// Simple list row (search results / library) — leading art + title/subtitle.
struct NListRow: View {
    @Environment(\.theme) private var theme
    var seed: String
    var title: String
    var subtitle: String
    var data: Data? = nil
    var kind: SeededArtwork.Kind = .playlist
    /// When set, the row resolves the playlist's hi-res cover on demand (Library list).
    var playlist: Playlist? = nil
    /// Smart playlists render our accent-gradient cover with a glyph (never a track's art).
    var smart: Bool = false
    var smartSymbol: String = "heart.fill"
    /// Hide the trailing chevron when the row is a `NavigationLink` inside a `List`
    /// (which already draws its own disclosure indicator).
    var showChevron: Bool = true
    /// Show a small pin glyph (Library pinned items).
    var pinned: Bool = false
    var size: CGFloat = 58

    var body: some View {
        HStack(spacing: 12) {
            if smart {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(theme.accent.fillGradient)
                    .overlay { Image(systemName: smartSymbol).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white) }
                    .frame(width: size, height: size)
            } else if let playlist {
                PlaylistArtwork(playlist: playlist, size: size)
            } else if kind == .artist && data == nil {
                // Resolve the artist's real cover (cached by TelegramService), matching the
                // Home shelf — a plain seeded Artwork would never show a photo.
                NArtistAvatar(name: seed, size: size)
            } else {
                Artwork(data: data, seed: seed, size: size, kind: kind, circle: kind == .artist)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(theme.text).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(theme.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            if pinned {
                // Telegram's pinnedBadge is a muted gray that flips per theme (#b6b6bb light /
                // #767677 dark); our tertiary-text token is the theme-adaptive equivalent.
                Image(systemName: "pin.fill").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
            if showChevron {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text3)
            }
        }
        .padding(.vertical, 6).contentShape(Rectangle())
    }
}

private struct NPulsingSkeleton: View {
    @Environment(\.theme) private var theme
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(theme.elev2)
            .frame(width: 150, height: 150)
            .opacity(pulse ? 0.6 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

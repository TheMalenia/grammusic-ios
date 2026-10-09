import SwiftUI

/// A Telegram user's profile music playlist in Nocturne style.
/// Displays the user's avatar, title (e.g. "Hasan's Playlists"), Play / Shuffle buttons,
/// find-in-profile search, pull-down refresh, and the list of tracks on their Telegram profile.
struct NProfilePlaylistDetailView: View {
    let profile: UserProfilePlaylist
    var showBackButton: Bool = true

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerEngine.self) private var player
    @Environment(NActionFeedback.self) private var feedback: NActionFeedback?
    @Environment(TelegramService.self) private var telegram
    @Environment(ImportStore.self) private var importStore

    @State private var selection = NTrackSelection()
    @State private var tracks: [AudioTrack] = []
    @State private var isLoading = false
    @State private var actionTarget: AudioTrack?
    @State private var showSearch = false
    @State private var showBlockConfirm = false
    @State private var newestFirst = true

    private var sortedTracks: [AudioTrack] { newestFirst ? tracks : tracks.reversed() }

    private var fullCollectionLoader: TrackCollectionLoader {
        let order = newestFirst
        return {
            let loaded = try await telegram.allProfileAudio(userId: profile.userId)
            return order ? loaded : loaded.reversed()
        }
    }

    private var meta: String {
        "Telegram Profile · \(tracks.count) track\(tracks.count == 1 ? "" : "s")"
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScreenBackground()

            LinearGradient(
                colors: [ArtworkSeed(profile.userName).accent.opacity(0.55),
                         ArtworkSeed(profile.userName).accent.opacity(0.18),
                         theme.bg.opacity(0)],
                startPoint: .top, endPoint: .bottom)
                .frame(height: 360).frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .top).allowsHitTesting(false)

            if showBackButton {
                mainList
                    .refreshable { await refresh() }
            } else {
                mainList
            }

            if showBackButton {
                topBar
            }
        }
        .trackSelection(tracks: sortedTracks, selection: selection, loadAll: fullCollectionLoader)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipe()
        .sheet(item: $actionTarget) { track in NTrackActionsSheet(track: track) }
        .alert("Block \(profile.userName)?", isPresented: $showBlockConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Block", role: .destructive) {
                Task {
                    await telegram.block(profile: profile)
                    importStore.hideProfile(profile.userId)
                    dismiss()
                }
            }
        } message: {
            Text("You won't see their music again, and it will be removed from your library and queue right away.")
        }
        .navigationDestination(isPresented: $showSearch) {
            NSearchView(
                localScope: .init(title: profile.title, tracks: sortedTracks, context: profile.title, loadAll: fullCollectionLoader),
                isTab: true, embeddedInNavigation: true,
                onClose: { NScopedSearchTransition.setPresented(false, using: $showSearch) })
        }
        .task(id: profile.userId) {
            tracks = profile.tracks
            await refresh()
        }
    }

    private var mainList: some View {
        List {
            Section {
                hero
                    .listRowInsets(EdgeInsets(top: showBackButton ? 70 : 30, leading: 16, bottom: 12, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                trackList
                
                Color.clear.frame(height: telegram.isOfflineStable ? 64 : 24)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(width: 38, height: 38)
                    .nocturneGlass(Circle(), theme: theme)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(NPressable(scale: 0.9))
            .accessibilityLabel("Back")

            Spacer()

            // This screen had no overflow menu at all, so a profile-music playlist — which belongs
            // to another person, and is user-generated content like any chat — offered no way to
            // hide it or block its owner.
            Menu {
                Button(role: .destructive) { showBlockConfirm = true } label: {
                    Label("Block User", systemImage: "hand.raised.fill")
                }
                Button {
                    importStore.hideProfile(profile.userId)
                    dismiss()
                } label: {
                    Label("Hide from Library", systemImage: "eye.slash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(width: 38, height: 38)
                    .nocturneGlass(Circle(), theme: theme)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 14) {
            NProfileAvatar(profile: profile, size: 148)
                .shadow(color: theme.shadow.opacity(0.5), radius: 18, y: 10)

            VStack(spacing: 4) {
                Text(profile.title)
                    .font(.display(26, .bold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text(meta)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.text2)
            }

            if !sortedTracks.isEmpty {
                HStack(spacing: 12) {
                    Pill(title: "Play", systemImage: "play.fill", variant: .primary, fullWidth: true) {
                        player.isShuffle = false
                        player.play(tracks: sortedTracks, context: profile.title)
                    }

                    Pill(title: "Shuffle", systemImage: "shuffle", variant: .light, fullWidth: true) {
                        player.shufflePlay(tracks: sortedTracks, context: profile.title)
                    }
                }
                .padding(.top, 4)

                controlRow

                SearchBarButton(prompt: "Find in profile playlist") {
                    NScopedSearchTransition.setPresented(true, using: $showSearch)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Sort toggle (left) + Download all (right).
    private var controlRow: some View {
        // Explicit-only: the playing track and its lookahead download too, and this button
        // must never offer to stop those.
        let downloading = tracks.filter { telegram.isExplicitlyDownloading($0) }.count
        return HStack {
            Button {
                withAnimation(.snappy(duration: 0.2)) { newestFirst.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: newestFirst ? "arrow.down" : "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                    Text(newestFirst ? "Newest" : "Oldest").font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(theme.text2)
            }
            .buttonStyle(NPressable(scale: 0.95))
            .accessibilityLabel("Sort order, \(newestFirst ? "newest first" : "oldest first")")

            Spacer()

            Button {
                if downloading > 0 { telegram.stopDownloads(tracks) }
                else { telegram.downloadAll(tracks) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: downloading > 0 ? "stop.circle" : "arrow.down.circle")
                        .font(.system(size: 13, weight: .semibold))
                    Text(downloading > 0 ? "Stop (\(downloading))" : "Download all")
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1).fixedSize()
                }
                .foregroundStyle(theme.accentColor)
            }
            .buttonStyle(NPressable(scale: 0.95))
            .accessibilityLabel(downloading > 0 ? "Stop downloading" : "Download all")
        }
        .sensoryFeedback(.selection, trigger: newestFirst)
    }

    // MARK: Track List

    @ViewBuilder private var trackList: some View {
        if isLoading && sortedTracks.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity).padding(.top, 40)
                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
        } else if sortedTracks.isEmpty {
            Text("No audio on this profile.")
                .font(.system(size: 15)).foregroundStyle(theme.text2)
                .frame(maxWidth: .infinity).padding(.top, 40)
                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
        } else {
            ForEach(Array(sortedTracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(
                    title: track.displayTitle,
                    subtitle: track.displaySubtitle,
                    seed: track.remoteUniqueId,
                    track: track,
                    isActive: player.current?.remoteUniqueId == track.remoteUniqueId,
                    isPlaying: player.isPlaying,
                    downloaded: telegram.isDownloaded(track),
                    duration: track.formattedDuration,
                    onTap: {
                        player.play(tracks: sortedTracks, startAt: index, context: profile.title)
                    },
                    onMore: { actionTarget = track }
                )
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .leading) {
                    if !selection.isSelecting {
                        Button { player.addToQueue(track, feedback: feedback) } label: {
                            Label("Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                        }
                        .tint(theme.accentColor)
                    }
                }

            }
        }
    }

    // MARK: Refresh

    private func refresh() async {
        isLoading = true
        let refreshed = await telegram.refreshUserProfile(for: profile)
        if !refreshed.isEmpty {
            tracks = refreshed
        }
        isLoading = false
    }
}

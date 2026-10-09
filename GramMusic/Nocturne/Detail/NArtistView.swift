import SwiftUI

/// An artist's audio found across the user's chats (screens §8). A full-bleed cover with the
/// artist name overlaid, a Follow / shuffle / play action row, then the artist's tracks.
struct NArtistView: View {
    let artist: Artist

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerEngine.self) private var player
    @Environment(NActionFeedback.self) private var feedback: NActionFeedback?
    @Environment(TelegramService.self) private var telegram

    @State private var tracks: [AudioTrack] = []
    @State private var cover: Data?
    @State private var isLoading = true
    @State private var error: String?
    @State private var addTarget: AudioTrack?
    @State private var actionTarget: AudioTrack?
    @State private var reportTarget: AudioTrack?
    @State private var showSearch = false

    private let coverHeight: CGFloat = 340
    private var following: Bool { telegram.isFollowing(artist: artist.name) }

    var body: some View {
        ZStack(alignment: .top) {
            ScreenBackground()

            List {
                Section {
                    coverHero
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    actionRow
                        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
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
            .ignoresSafeArea(edges: .top)

            backButton
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipe()      // restore edge-swipe-back (hidden bar disables it)
        .sheet(item: $addTarget) { track in NAddToPlaylistSheet(track: track) }
        .sheet(item: $actionTarget) { track in NTrackActionsSheet(track: track) }
        .sheet(item: $reportTarget) { t in NReportSheet(chatId: t.chatId, messageIds: [t.messageId], onDismiss: { reportTarget = nil }) }
        .navigationDestination(isPresented: $showSearch) {
            NSearchView(
                localScope: .init(title: artist.name, tracks: tracks, context: artist.name),
                isTab: true, embeddedInNavigation: true,
                onClose: { NScopedSearchTransition.setPresented(false, using: $showSearch) })
        }
        .task(id: artist.id) { await load() }
    }

    // MARK: Cover hero

    private var coverHero: some View {
        let activeCover = cover ?? telegram.quickArtistArtwork(for: artist.name)
        return ZStack(alignment: .bottomLeading) {
            Group {
                if let activeCover, let ui = UIImage(data: activeCover) {
                    Image(uiImage: ui).resizable().scaledToFill()
                } else {
                    SeededArtwork(seed: artist.name, style: theme.artwork, kind: .artist,
                                  size: coverHeight, fillsContainer: true)
                }
            }
            .frame(height: coverHeight)
            .frame(maxWidth: .infinity)
            .clipped()

            LinearGradient(colors: [.clear, .clear, theme.bg.opacity(0.7), theme.bg],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name).font(.display(38, .bold)).tracking(-0.6)
                    .foregroundStyle(.white).lineLimit(2)
                Text("in your chats").font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
            }
            .padding(16)
        }
        .frame(height: coverHeight)
        .frame(maxWidth: .infinity)
    }

    // MARK: Action row

    private var actionRow: some View {
        HStack(spacing: 14) {
            Pill(title: following ? "Following" : "Follow",
                 systemImage: following ? "checkmark" : "plus",
                 variant: following ? .ghost : .primary, size: .md) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    telegram.toggleFollow(artist: artist.name)
                }
            }

            Spacer()

            IconButton(systemName: "shuffle", size: 20) {
                guard !tracks.isEmpty else { return }
                player.shufflePlay(tracks: tracks, context: artist.name)
            }
            .accessibilityLabel("Shuffle")

            Button {
                guard !tracks.isEmpty else { return }
                player.isShuffle = false
                player.play(tracks: tracks, context: artist.name)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.accentText)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(theme.brandFill))
                    .shadow(color: theme.accentColor.opacity(0.3), radius: 14, y: 8)
            }
            .buttonStyle(NPressable(scale: 0.94))
            .disabled(tracks.isEmpty)
            .accessibilityLabel("Play")
        }
    }

    // MARK: Tracks

    @ViewBuilder private var tracksSection: some View {
        SectionTitle(title: "Tracks")
            .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

        if tracks.count > 4 {
            SearchBarButton(prompt: "Find in \(artist.name)") {
                NScopedSearchTransition.setPresented(true, using: $showSearch)
            }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }

        if isLoading {
            ForEach(0..<6, id: \.self) { _ in
                skeletonRow
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        } else if tracks.isEmpty {
            Text(error ?? "No audio by \(artist.name) found in your chats.")
                .font(.system(size: 15)).foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.top, 30).padding(.horizontal, 24)
                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
        } else {
            ForEach(tracks) { track in
                TrackRow(title: track.displayTitle,
                         subtitle: track.displaySubtitle,
                         seed: track.remoteUniqueId,
                         track: track,
                         isActive: player.current?.remoteUniqueId == track.remoteUniqueId,
                         isPlaying: player.isPlaying,
                         downloaded: telegram.isDownloaded(track),
                         duration: track.formattedDuration,
                         onTap: { playFrom(track) },
                         onMore: { actionTarget = track })
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .leading) {
                        Button { player.addToQueue(track, feedback: feedback) } label: {
                            Label("Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                        }
                        .tint(theme.accentColor)
                    }
                    .contextMenu {
                        NTrackContextMenu(
                            track: track,
                            onAddToPlaylist: { addTarget = track },
                            onReport: { reportTarget = track }
                        )
                    }
            }
        }
    }

    private var skeletonRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.elev2).frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(theme.elev2).frame(width: 160, height: 12)
                RoundedRectangle(cornerRadius: 4).fill(theme.elev2).frame(width: 100, height: 10)
            }
            Spacer()
        }
        .padding(.vertical, 10).redacted(reason: .placeholder)
    }

    private var backButton: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.black.opacity(0.28)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(NPressable(scale: 0.9))
            .accessibilityLabel("Back")
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Loading

    private func load() async {
        // Show the last-seen tracks immediately (works offline); only spin if we have nothing.
        let cached = telegram.cachedArtistTracks(artist.name)
        if !cached.isEmpty { tracks = cached; isLoading = false } else { isLoading = true }
        defer { isLoading = false }

        // Concurrently resolve the highest-res artist artwork
        Task {
            if let freshCover = await telegram.artistArtwork(for: artist.name) {
                await MainActor.run {
                    self.cover = freshCover
                }
            }
        }

        do {
            let results = try await telegram.searchAudio(artist.name)
            // `searchAudio` already de-duplicates on `remoteUniqueId`; this narrows the global
            // match to tracks actually *by* this performer, folding the name the same way the
            // search engine does so "Beyoncé" and "Beyonce" are one artist.
            let filtered = results.filter { AudioSearch.matches($0.performer, query: artist.name) }
            tracks = filtered
            telegram.cacheArtistTracks(filtered, name: artist.name)
            error = nil

            // Re-evaluate artist cover with the freshly fetched tracks to upgrade to high-res if available
            Task {
                if let betterCover = await telegram.refreshArtistCover(for: artist.name, tracks: filtered) {
                    await MainActor.run {
                        self.cover = betterCover
                    }
                }
            }
        } catch {
            // Keep showing the cache when offline; only surface an error if we have nothing.
            if tracks.isEmpty {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func playFrom(_ track: AudioTrack) {
        let start = tracks.firstIndex { $0.id == track.id } ?? 0
        player.play(tracks: tracks, startAt: start, context: artist.name)
    }
}

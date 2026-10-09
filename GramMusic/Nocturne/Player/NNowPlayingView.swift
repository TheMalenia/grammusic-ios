import SwiftUI
import UIKit
import CoreImage

/// Now Playing (screens §9). Presented full-screen by `InteractivePlayerHost`, which owns the
/// native swipe-down dismiss from the top of the player scroll. The controls lead into a
/// stack of discovery cards; full lyrics open separately from the preview.
struct NNowPlayingView: View {
    @Environment(\.theme) private var theme
    @Environment(PlayerEngine.self) private var player
    @Environment(TelegramService.self) private var telegram
    @Environment(AppSettings.self) private var settings
    @Environment(NActionFeedback.self) private var feedback
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isInteractiveDismissing) private var isInteractiveDismissing

    /// Closes the player (runs the host's interactive dismiss animation). The hosted view has no
    /// `@Environment(\.dismiss)`, so the chevron routes through here.
    var onClose: () -> Void = {}
    /// Lets the shell open the source in its existing Library navigation stack. Without a shell
    /// route, source badges retain their local-sheet behavior.
    var onOpenSource: ((NPlayerSourceRoute) -> Void)? = nil

    @State private var showQueue = false
    @State private var showArtist = false
    @State private var showAddToPlaylist = false
    @State private var showAirPlay = false
    @State private var showChat: TelegramChat?
    @State private var showChatNowPlaying = false
    @State private var showProfile: UserProfilePlaylist?
    @State private var showYourProfile = false
    @State private var showShareSheet = false
    @State private var lyrics: Lyrics?
    @State private var lyricsLoading = false
    @State private var coverColor: Color?
    @State private var showLyrics = false
    @State private var carouselIndex: Int?

    private var service: PlaylistService { PlaylistService(context: context) }
    /// Derived from the shared favourites mirror, so liking here also updates every
    /// list showing the same track (and vice versa).
    private var isFavoriteTrack: Bool {
        guard let track = player.current else { return false }
        return telegram.isFavorite(track)
    }

    private func artworkSize(in container: CGSize) -> CGFloat {
        guard container.width.isFinite, container.height.isFinite else { return 0 }
        return max(0, min(container.width - 40, container.height * 0.42, 380))
    }

    private var lyricsTaskKey: String {
        "\(player.current?.remoteUniqueId ?? "")|\(settings.lyricsEnabled)"
    }

    private func openSource(_ route: NPlayerSourceRoute) {
        if let onOpenSource {
            onOpenSource(route)
            return
        }
        switch route {
        case .chat(let chat): showChat = chat
        case .profile(let profile): showProfile = profile
        case .ownProfile: showYourProfile = true
        }
    }

    var body: some View {
        GeometryReader { proxy in
        ZStack {
            if let track = player.current {
                backdrop.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Grabber + header. (The sheet itself handles swipe-down-to-dismiss.)
                    VStack(spacing: 0) {
                        Capsule().fill(.white.opacity(0.5))
                            .frame(width: 40, height: 5)
                            .padding(.top, 8).padding(.bottom, 12)
                            .accessibilityHidden(true)
                        header(track)
                            .padding(.horizontal, 24)
                    }
                    .zIndex(1)

                    ScrollViewReader { scroll in
                        ScrollView(.vertical) {
                            VStack(spacing: 20) {
                                playerPage(track, art: artworkSize(in: proxy.size))
                                    .frame(minHeight: max(0, proxy.size.height - 140))
                                    .id("player")

                                // Add future discovery cards (artist, credits, etc.) to this stack.
                                VStack(spacing: 16) {
                                    if settings.lyricsEnabled {
                                        NLyricsPreviewCard(
                                            lyrics: lyrics,
                                            isLoading: lyricsLoading,
                                            tint: coverColor ?? seedAccent,
                                            showLyrics: { showLyrics = true }
                                        )
                                    }
                                }
                                .padding(.horizontal, 24)
                                .padding(.bottom, max(32, proxy.safeAreaInsets.bottom + 16))
                            }
                        }
                        .onChange(of: lyricsTaskKey) { _, _ in
                            scroll.scrollTo("player", anchor: .top)
                        }
                    }
                    .scrollIndicators(.hidden)
                    .nHideScrollEdgeEffect()
                    .contentMargins(.vertical, 0, for: .scrollContent)
                    // Let cards scroll through the home-indicator area to the phone's edge.
                    .ignoresSafeArea(.container, edges: .bottom)
                }
                .foregroundStyle(.white)
            } else {
                backdrop.ignoresSafeArea()
                ContentUnavailableView("Nothing playing", systemImage: "music.note")
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        // Resolve backdrop tint once per track.
        .task(id: player.current?.remoteUniqueId) {
            coverColor = nil
            guard let track = player.current else { return }
            if let data = await telegram.highResArtwork(for: track) {
                let color = await Self.backdropColor(from: data)
                guard !Task.isCancelled else { return }
                coverColor = color
            }
        }
        // Resolve lyrics once per track (and lyrics toggle state).
        .task(id: lyricsTaskKey) {
            lyrics = nil
            lyricsLoading = settings.lyricsEnabled
            guard let track = player.current, settings.lyricsEnabled else {
                showLyrics = false
                lyricsLoading = false
                return
            }
            let resolved = await telegram.lyrics(for: track)
            guard !Task.isCancelled else { return }
            lyrics = resolved
            lyricsLoading = false
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
        .sensoryFeedback(.selection, trigger: player.isShuffle)
        .sensoryFeedback(.selection, trigger: player.repeatMode)
        .sensoryFeedback(.impact(weight: .light), trigger: isFavoriteTrack)
        .sheet(isPresented: $showLyrics) {
            if let track = player.current {
                NLyricsSheet(lyrics: lyrics, isLoading: lyricsLoading,
                             track: track, tint: coverColor ?? seedAccent)
            }
        }
        .sheet(isPresented: $showQueue) { NQueueView() }
        .sheet(isPresented: $showArtist) {
            if let name = player.current?.performer, !name.isEmpty {
                NavigationStack {
                    NArtistView(artist: Artist(name: name))
                        .nMusicDestinations()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showArtist = false }
                            }
                        }
                }
            }
        }
        .sheet(item: $showChat) { chat in
            NavigationStack {
                NChatAudioView(chat: chat, showBackButton: false)
                    .nMusicDestinations()
            }
            .environment(\.nUsesNativePlayerAccessory, false)
            .nMiniDock { showChatNowPlaying = true }
            .nowPlayingPresentation(isPresented: $showChatNowPlaying)
        }
        .sheet(item: $showProfile) { profile in
            NavigationStack {
                NProfilePlaylistDetailView(profile: profile, showBackButton: false)
                    .nMusicDestinations()
            }
        }
        .sheet(isPresented: $showYourProfile) {
            NavigationStack {
                NPlaylistDetailView(playlist: service.profilePlaylist())
                    .nMusicDestinations()
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.current { NAddToPlaylistSheet(track: track) }
        }
        .sheet(isPresented: $showAirPlay) {
            NAirPlaySheet().presentationDetents([.height(280)])
        }
        .sheet(isPresented: $showShareSheet) {
            if let track = player.current {
                NShareSheetView(track: track)
                    .presentationDetents([.large])
            }
        }
        }
    }

    // MARK: Player page

    private func playerPage(_ track: AudioTrack, art: CGFloat) -> some View {
        // Apple-Music-style distribution: artwork near the top, then the control block centred in the
        // lower half via flexible spacers (rather than clustered tight under the artwork), with
        // generous spacing between each row.
        VStack(spacing: 0) {
            artworkCarousel(size: art)
                .padding(.top, 4)

            Spacer(minLength: 20)

            // Name + scrubber + transport + download kept as one tight group (close spacing).
            VStack(spacing: 0) {
                trackInfo(track)
                // A leaf that reads `currentTime` itself, so the (heavy) player body doesn't rebuild on
                // every 0.5s playback tick — which is what made a slow swipe-down hitch.
                PlayerScrubber()
                    .padding(.top, 16)
                transport
                    .padding(.top, 16)
                bottomBar(track)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 12)
    }

    private var seedAccent: Color {
        guard let id = player.current?.remoteUniqueId else { return theme.accentColor }
        return ArtworkSeed(id).accent
    }

    private var backdrop: some View {
        let base = coverColor ?? seedAccent
        return AuroraBackdrop(baseColor: base)
            .animation(.easeInOut(duration: 0.6), value: base)
    }

    private static func backdropColor(from data: Data) async -> Color? {
        await Task.detached(priority: .utility) { () -> Color? in
            guard let ui = UIImage(data: data), let cg = ui.cgImage else { return nil }
            let input = CIImage(cgImage: cg)
            let e = input.extent
            let extent = CIVector(x: e.origin.x, y: e.origin.y, z: e.width, w: e.height)
            guard let filter = CIFilter(name: "CIAreaAverage",
                                        parameters: [kCIInputImageKey: input, kCIInputExtentKey: extent]),
                  let output = filter.outputImage else { return nil }
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CIContext(options: [.workingColorSpace: NSNull()])
            ctx.render(output, toBitmap: &px, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
                .getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            return Color(UIColor(hue: h, saturation: min(s * 1.25, 0.85),
                                 brightness: min(max(b, 0.30), 0.52), alpha: 1))
        }.value
    }

    // MARK: Header

    private func header(_ track: AudioTrack) -> some View {
        HStack {
            Button { onClose() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Close player")

            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text("PLAYING FROM")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.6))
                Text(player.contextName ?? "Telegram")
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            Color.clear.frame(width: 44, height: 44)
        }
    }

    // MARK: Artwork

    private func artworkCarousel(size: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(Array(player.entries.enumerated()), id: \.offset) { index, entry in
                    VStack(spacing: 0) {
                        ZStack(alignment: .topTrailing) {
                            TrackArtwork(track: entry.track, size: size)
                                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                                .shadow(color: .black.opacity(0.5), radius: 22, y: 24)
                            
                            sourceBadge(for: entry.track)
                        }
                        .scaleEffect((index == player.currentIndex && player.isPlaying) ? 1.0 : 0.86)
                        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.7),
                                   value: player.isPlaying)
                        .padding(.top, 30)
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 60)
                    .containerRelativeFrame(.horizontal)
                    .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollDisabled(isInteractiveDismissing)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $carouselIndex)
        .frame(height: size + 90)
        .padding(.bottom, -60)
        .onChange(of: player.currentIndex, initial: true) { _, newIndex in
            if carouselIndex != newIndex {
                let distance = abs(newIndex - (carouselIndex ?? newIndex))
                if distance == 1 {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85)) {
                        carouselIndex = newIndex
                    }
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        carouselIndex = newIndex
                    }
                }
            }
        }
        .onChange(of: carouselIndex) { _, newIndex in
            if let newIndex, newIndex != player.currentIndex {
                player.jump(to: newIndex)
            }
        }
    }

    private var scaleForPlayState: CGFloat {
        player.isPlaying ? 1.0 : 0.86
    }

    @ViewBuilder
    private func sourceBadge(for track: AudioTrack) -> some View {
        switch NPlayerSourceRoute.resolve(track: track, contextName: player.contextName,
                                          chats: telegram.chats, profiles: telegram.userProfiles,
                                          isOwnProfileAudio: telegram.isProfileAudio(track)) {
        case .chat(let chat):
            FloatingChatBadge(chat: chat) { openSource(.chat(chat)) }
                .offset(x: 12, y: -12)
        case .profile(let profile):
            FloatingProfileBadge(profile: profile) { openSource(.profile(profile)) }
                .offset(x: 12, y: -12)
        case .ownProfile:
            FloatingYourProfileBadge { openSource(.ownProfile) }
                .offset(x: 12, y: -12)
        case nil:
            EmptyView()
        }
    }

    // MARK: Track info

    private func trackInfo(_ track: AudioTrack) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                NMarqueeText {
                    Text(track.displayTitle)
                        // Bricolage Grotesque has no Persian/Arabic glyphs, so it falls back unevenly for
                        // those titles — use the same system font as the lyrics there instead.
                        .font(track.displayTitle.containsPersian
                              ? .title2.weight(.bold)
                              : .display(25, .bold))
                        .foregroundStyle(.white)
                }
                
                Button { showArtist = true } label: {
                    NMarqueeText {
                        Text(track.displaySubtitle)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .buttonStyle(.plain)
                .disabled(track.performer.isEmpty)
            }
            Spacer(minLength: 0)
            Button {
                feedback.toggleFavorite(track, in: telegram)
            } label: {
                Image(systemName: isFavoriteTrack ? "heart.fill" : "heart")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFavoriteTrack ? theme.accentColor : .white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            }
            .accessibilityLabel(isFavoriteTrack ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityValue(isFavoriteTrack ? "In Favorites" : "Not in Favorites")
        }
        .padding(.bottom, 6)
    }

    // MARK: Transport

    private var transport: some View {
        HStack {
            Button { player.isShuffle.toggle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.isShuffle ? theme.accentColor : .white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .overlay(alignment: .bottom) {
                if player.isShuffle {
                    Circle().fill(theme.accentColor).frame(width: 4, height: 4)
                }
            }
            .accessibilityLabel("Shuffle")
            .accessibilityValue(player.isShuffle ? "On" : "Off")
            Spacer(minLength: 0)

            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    player.previous()
                }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Previous track")
            Spacer(minLength: 0)

            playPauseButton
            Spacer(minLength: 0)

            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    player.next()
                }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .opacity(player.hasNext ? 1 : 0.4)
            .disabled(!player.hasNext)
            .accessibilityLabel("Next track")
            Spacer(minLength: 0)

            Button { player.cycleRepeatMode() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.repeatMode == .off ? .white : theme.accentColor)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .overlay(alignment: .bottom) {
                if player.repeatMode != .off {
                    Circle().fill(theme.accentColor).frame(width: 4, height: 4)
                }
            }
            .accessibilityLabel("Repeat mode")
            .accessibilityValue(player.repeatMode == .off ? "Off" : (player.repeatMode == .one ? "Repeat one" : "Repeat all"))
        }
        .foregroundStyle(.white)
    }

    private var playPauseButton: some View {
        Group {
            if player.isLoading {
                ProgressView()
                    .tint(.black)
                    .controlSize(.large)
                    .frame(width: 74, height: 74)
                    .background(Circle().fill(.white))
            } else {
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.black)
                        .frame(width: 74, height: 74)
                        .background(Circle().fill(.white))
                        .shadow(color: .white.opacity(player.isPlaying ? 0.25 : 0), radius: 16)
                        .contentShape(Circle())
                        .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                }
                .buttonStyle(NPressable(scale: 0.94))
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            }
        }
    }

    // MARK: Bottom utility bar

    private func bottomBar(_ track: AudioTrack) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 16) {
                NRoutePicker(tint: .white, activeTint: theme.accentColor)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("AirPlay")

                secondaryButton(systemName: "square.and.arrow.up", active: false, label: "Share") {
                    showShareSheet = true
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 16) {
                secondaryButton(systemName: "text.badge.plus", active: false, label: "Add to playlist") {
                    showAddToPlaylist = true
                }

                DownloadControl(track: track)

                secondaryButton(systemName: "list.bullet", active: false, label: "Queue") {
                    showQueue = true
                }
            }
        }
    }

    private func secondaryButton(systemName: String,
                                 active: Bool,
                                 label: String,
                                 badge: String? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(active ? theme.accentColor : .white)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(active ? theme.accentColor : .white)
                        .offset(y: 15)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(NPressable(scale: 0.9))
        .accessibilityLabel(label)
    }
}

// MARK: - High-frequency leaves
//
// `currentTime` ticks at 2Hz while playing. Reading it here, in tiny leaf views, means only these
// leaves re-render on each tick — the rest of the player body stays put instead of rebuilding the
// whole screen twice a second.

/// The scrubber, isolated so the playback tick doesn't rebuild the player.
private struct PlayerScrubber: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        Scrubber(currentTime: player.currentTime,
                 duration: player.duration,
                 bufferedTime: player.bufferedTime,
                 overArt: true,
                 onSeek: { player.seek(to: $0) })
    }
}

/// The Now Playing download button — a **toggle**, in all three of its states.
///
/// It used to be one-way: once downloaded it went filled and `.disabled`, so the only way to undo
/// a download was to find the track again in a list and use its action sheet. Tapping the control
/// that put it there is the obvious way to take it back out.
private struct DownloadControl: View {
    let track: AudioTrack
    @Environment(TelegramService.self) private var telegram
    @Environment(\.theme) private var theme
    @State private var confirmRemove = false

    private var isDownloaded: Bool { telegram.isDownloaded(track) }

    var body: some View {
        Button {
            if telegram.downloadFraction(for: track) != nil {
                telegram.removeDownload(track)          // tapping mid-download cancels it
            } else if isDownloaded {
                // Only ask when the bytes are genuinely about to go *and* Telegram no longer has a
                // copy to re-fetch. When the removal keeps the file as cache there is nothing to
                // lose, so a warning would be a lie.
                if telegram.isUnavailableOnTelegram(track),
                   !telegram.removalKeepsFile(track.remoteUniqueId) {
                    confirmRemove = true
                } else {
                    telegram.removeDownload(track)
                }
            } else {
                telegram.download(track)
            }
        } label: {
            ZStack {
                if let fraction = telegram.downloadFraction(for: track) {
                    DownloadRing(progress: fraction).frame(width: 22, height: 22)
                } else {
                    Image(systemName: isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(isDownloaded ? theme.accentColor : .white)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(NPressable(scale: 0.9))
        .accessibilityLabel(accessibilityLabel)
        .confirmationDialog("Remove this download?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { telegram.removeDownload(track) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This track is no longer on Telegram, so removing the download deletes your only copy.")
        }
    }

    private var accessibilityLabel: String {
        if telegram.downloadFraction(for: track) != nil { return "Cancel download" }
        return isDownloaded ? "Remove download" : "Download"
    }
}

private extension View {
    /// Hide the iOS 26 scroll-edge effect (the faint band/blur at a scroll view's edges).
    /// No-op before iOS 26.
    @ViewBuilder func nHideScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}

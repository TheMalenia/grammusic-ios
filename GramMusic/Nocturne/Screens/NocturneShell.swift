import SwiftUI

/// Nocturne app root. Injects the resolved theme + accent tint, forces the theme's color
/// scheme, shows the cold-launch splash, and routes by auth state. (During migration it
/// reuses the existing `AuthFlowView` login and `.miniPlayerBar()` so playback keeps working;
/// the redesigned login/import/player land in later passes.)
struct NocturneRootView: View {
    @Environment(TelegramService.self) private var telegram
    @Environment(AppSettings.self) private var settings
    @Environment(ImportStore.self) private var importStore
    @Environment(\.colorScheme) private var systemScheme
    @State private var feedback = NActionFeedback()

    private var shouldShowShell: Bool {
        if telegram.authState == .ready { return true }
        // A cached session shows the shell during the initializing flash so a relaunch doesn't
        // blink the login screen — but not once we know the session ended (remote sign-out),
        // which would otherwise briefly show the signed-out shell.
        if telegram.authState == .initializing,
           telegram.hasCachedSession,
           telegram.sessionExpiredNotice == nil { return true }
        return false
    }

    var body: some View {
        ZStack {
            if shouldShowShell {
                NocturneAppShell()
            } else {
                NLoginView()
            }
        }
        .environment(feedback)
        .nocturneTheme(settings, scheme: systemScheme)
        .preferredColorScheme(settings.preferredColorScheme)
        .animation(.easeInOut(duration: 0.25), value: shouldShowShell)
        .onChange(of: telegram.authState) { _, newState in
            // Detecting a remote sign-out lives in `TelegramService` (it also has to wipe the
            // account's local data and stop playback, which a view must not be responsible for).
            // All this needs to do is dismiss the keyboard when a login completes.
            if newState == .waitingForPhoneNumber { feedback.dismiss() }
            if newState == .ready {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }
}

/// Home, Library, Settings and Search share system navigation and a native player accessory
/// on iOS 26.1+, with conventional per-tab docks on older versions. Now Playing is presented
/// **full-screen** (`InteractivePlayerHost`) with a native swipe-down dismiss.
struct NocturneAppShell: View {
    /// Allows the conventional compatibility layout to be exercised on current simulators.
    var prefersNativePlayerAccessory = true
    @Environment(PlayerEngine.self) private var player
    @Environment(TelegramService.self) private var telegram
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @State private var selection = 0
    @State private var pendingPlayerSource: NPlayerSourceRoute?
    @State private var dockTop: CGFloat?
    @State private var offlineTop: CGFloat?
    @State private var shellBottom: CGFloat = 0
    @State private var searchInput = NSearchInput()

    init(prefersNativePlayerAccessory: Bool = true, searchInput: NSearchInput = NSearchInput()) {
        self.prefersNativePlayerAccessory = prefersNativePlayerAccessory
        _searchInput = State(initialValue: searchInput)
    }

    /// TabView writes selection again on a repeated tap; keep navigation and focus separate.
    private var tabSelection: Binding<Int> {
        Binding(get: { selection }, set: { tab in
            if tab == 4 && selection == 4 { searchInput.focusRequest += 1 }
            selection = tab
        })
    }

    private func openSearch() {
        selection = 4
    }

    private var feedbackClearance: CGFloat {
        let usesNative: Bool
        if #available(iOS 26.1, *) { usesNative = prefersNativePlayerAccessory } else { usesNative = false }
        let dockIsVisible = player.current != nil || (!usesNative && telegram.isOfflineStable)
        let top = [dockIsVisible ? dockTop : nil, telegram.isOfflineStable ? offlineTop : nil].compactMap { $0 }.min()
        return top.map { max(16, shellBottom - $0 + 12) } ?? 72
    }
    @AppStorage("n_hasSeenAITab") private var hasSeenAITab = false
    @State private var showNowPlaying = false
    @State private var showJoinChannel = false

    var body: some View {
        return Group {
            if #available(iOS 26.1, *), prefersNativePlayerAccessory {
                TabView(selection: tabSelection) {
                    Tab("Home", systemImage: "house", value: 0) { NHomeView(onSearch: openSearch).modifier(NOfflineDock(onTopChange: { offlineTop = $0 })) }
                    Tab("Library", systemImage: "books.vertical", value: 1) { NLibraryView(pendingPlayerSource: $pendingPlayerSource, onSearch: openSearch).modifier(NOfflineDock(onTopChange: { offlineTop = $0 })) }
                    if AppConfig.aiEnabled && settings.aiTabEnabled {
                        Tab("AI", systemImage: "sparkles", value: 2) { NAIView().modifier(NOfflineDock(onTopChange: { offlineTop = $0 })) }
                            .badge(hasSeenAITab ? nil : Text("New"))
                    }
                    Tab("Settings", systemImage: "gearshape", value: 3) { NSettingsView().modifier(NOfflineDock(onTopChange: { offlineTop = $0 })) }
                    Tab("Search", systemImage: "magnifyingglass", value: 4,
                        role: .search) {
                        NSearchView(isTab: true, sharedInput: searchInput).modifier(NOfflineDock(onTopChange: { offlineTop = $0 }))
                    }
                }
                .tabBarMinimizeBehavior(player.current == nil ? .never : .onScrollDown)
                // Keep the TabView's identity when playback starts/stops; an empty accessory
                // closure on 26.0 can leave a blank bar, hence the explicit 26.1 API.
                .tabViewBottomAccessory(isEnabled: player.current != nil) {
                    NTabMiniPlayer(onExpand: { showNowPlaying = true }, onTopChange: { dockTop = $0 })
                }
                .environment(\.nUsesNativePlayerAccessory, true)
                .environment(\.nMiniDockTop, [player.current == nil ? nil : dockTop,
                    telegram.isOfflineStable ? offlineTop : nil].compactMap { $0 }.min())
            } else {
                TabView(selection: tabSelection) {
                    NHomeView(onSearch: openSearch).nMiniDock(onDockTopChange: { dockTop = $0 }) { showNowPlaying = true }
                        .tabItem { Label("Home", systemImage: "house") }.tag(0)
                    NLibraryView(pendingPlayerSource: $pendingPlayerSource, onSearch: openSearch).nMiniDock(onDockTopChange: { dockTop = $0 }) { showNowPlaying = true }
                        .tabItem { Label("Library", systemImage: "books.vertical") }.tag(1)
                    if AppConfig.aiEnabled && settings.aiTabEnabled {
                        NAIView().nMiniDock(onDockTopChange: { dockTop = $0 }) { showNowPlaying = true }
                            .tabItem { Label("AI", systemImage: "sparkles") }.tag(2)
                            .badge(hasSeenAITab ? nil : "New")
                    }
                    NSettingsView().nMiniDock(onDockTopChange: { dockTop = $0 }) { showNowPlaying = true }
                        .tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
                    NSearchView(isTab: true, sharedInput: searchInput).nMiniDock(onDockTopChange: { dockTop = $0 }) { showNowPlaying = true }
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(4)
                }
            }
        }
        .background(ScreenBackground())
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { shellBottom = $0 }
        .onChange(of: selection) { _, tab in
            if tab == 2 { hasSeenAITab = true }
        }
        // Turning the tab off while standing on it would leave the shell on a tag that no longer
        // exists — an empty screen with no way back. Fall back to Library.
        .onChange(of: settings.aiTabEnabled) { _, enabled in
            if !enabled && selection == 2 { selection = 1 }
        }
        .overlay(alignment: .top) { TopStatusBarShadow() }
        .nowPlayingPresentation(isPresented: $showNowPlaying, onOpenSource: { source in
            showNowPlaying = false
            selection = 1
            pendingPlayerSource = source
        })
        // Playing a song updates the dock; browsing stays on the current screen.
        .actionFeedback(bottomClearance: feedbackClearance)
        // One-time invitation to @GramMusicApp. The lookup is silent and only qualifies when
        // Telegram actually says "not a member", so a failed check shows nothing at all.
        .task(id: telegram.connectionState) {
            guard !telegram.hasSeenCommunityPrompt, telegram.communityMembership != .member else { return }
            await telegram.refreshCommunityMembership()
            guard telegram.shouldShowCommunityPrompt, !showNowPlaying else { return }
            // Let the shell settle before taking over the screen on a cold launch.
            try? await Task.sleep(for: .seconds(1.2))
            guard telegram.shouldShowCommunityPrompt, !showNowPlaying else { return }
            showJoinChannel = true
        }
        .fullScreenCover(isPresented: $showJoinChannel, onDismiss: { telegram.hasSeenCommunityPrompt = true }) {
            NJoinChannelView { showJoinChannel = false }
        }
        .playbackErrorBanner()
    }


}

/// Docks the floating mini-player above the (system) tab bar inside a tab's content, so it sits
/// just above the Liquid Glass bar — the per-tab `safeAreaInset` approach CLAUDE.md settled on.
private struct NMiniDock: ViewModifier {
    @Environment(PlayerEngine.self) private var player
    @Environment(TelegramService.self) private var telegram
    let onExpand: () -> Void
    var onDockTopChange: ((CGFloat?) -> Void)?
    @State private var dockTop: CGFloat?
    @State private var dockHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .environment(\.nMiniDockTop, player.current != nil || telegram.isOfflineStable ? dockTop : nil)
            .environment(\.nMiniDockHeight, player.current != nil || telegram.isOfflineStable ? dockHeight : nil)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if telegram.isOfflineStable || player.current != nil {
                    VStack(spacing: 6) {
                        if telegram.isOfflineStable { OfflineBar() }
                        if player.current != nil {
                            NMiniPlayer(onExpand: onExpand)
                                // Slides down off the bottom when playback stops, fades in on first play.
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        dockTop = $0.minY
                        onDockTopChange?($0.minY)
                        dockHeight = $0.height
                    }
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: player.current == nil)
            .animation(.snappy, value: telegram.isOfflineStable)
            .onChange(of: player.current == nil && !telegram.isOfflineStable) { _, empty in
                if empty { onDockTopChange?(nil) }
            }
    }
}

/// Offline status reflects both explicit downloads and playable cached music.
struct OfflineBar: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            notice("No connection · Saved music available")
            notice("No connection")
            notice("Offline")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .nGlass(Capsule(), theme: theme, elevated: true)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No connection. Saved music is still available.")
    }

    private func notice(_ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).foregroundStyle(theme.text)
        } icon: {
            Image(systemName: "wifi.slash").foregroundStyle(theme.accentColor)
        }
        .font(.footnote.weight(.medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: true)
        .padding(.vertical, 8)
    }

}

extension View {
    func nMiniDock(onDockTopChange: ((CGFloat?) -> Void)? = nil, onExpand: @escaping () -> Void) -> some View {
        modifier(NMiniDock(onExpand: onExpand, onDockTopChange: onDockTopChange))
    }
}

/// A transient, auto-dismissing banner that surfaces `PlayerEngine.lastError` — a decode failure
/// or an unsupported container (Opus/Ogg, Matroska/WebM). Without it these fail silently: no
/// sound, no explanation. Applied at the shell root *and* over the Now Playing sheet (which is
/// auto-presented on play, so a failure usually happens with it open) — only one is ever visible
/// at a time since the sheet covers the shell's copy.
private struct PlaybackErrorBannerModifier: ViewModifier {
    @Environment(PlayerEngine.self) private var player
    @Environment(TelegramService.self) private var telegram
    @Environment(\.theme) private var theme

    /// Three sources, in priority order, and the order matters: a real playback failure outranks a
    /// failed action, which outranks a failed download. Downloads come last and are styled as a
    /// *notice* — a background download dying says nothing about the music currently playing, and
    /// dressing it as a playback error (which is what happened when downloads wrote `lastError`)
    /// made a healthy player look broken.
    private var active: (text: String, icon: String, isInfo: Bool)? {
        if let error = player.lastError {
            return (error, player.lastErrorIsInfo ? "info.circle.fill" : "exclamationmark.triangle.fill",
                    player.lastErrorIsInfo)
        }
        if let error = telegram.lastError {
            return (error, "exclamationmark.triangle.fill", false)
        }
        if let error = telegram.downloadError {
            return (error, "arrow.down.circle.fill", true)
        }
        return nil
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let active {
                let error = active.text
                let isInfo = active.isInfo
                HStack(spacing: 10) {
                    Image(systemName: active.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isInfo ? theme.accentColor : .orange)
                    Text(error)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.text)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button {
                        player.lastError = nil
                        telegram.lastError = nil
                        telegram.downloadError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.text2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .nGlass(RoundedRectangle(cornerRadius: 16, style: .continuous), theme: theme, elevated: true)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: error) {
                    // Auto-dismiss; a new error restarts the timer (id-keyed task).
                    try? await Task.sleep(for: .seconds(5))
                    if player.lastError == error { player.lastError = nil }
                    if telegram.lastError == error { telegram.lastError = nil }
                    if telegram.downloadError == error { telegram.downloadError = nil }
                }
            }
        }
        .animation(.snappy, value: active?.text)
    }
}

extension View {
    /// Surfaces playback failures (decode errors, unsupported Opus/Ogg) as a transient top banner.
    func playbackErrorBanner() -> some View { modifier(PlaybackErrorBannerModifier()) }
}

/// A full-screen loading overlay shown after login and during initial launch sync until data is ready.


extension View {
    /// Push routes to the Nocturne detail screens.
    func nMusicDestinations() -> some View {
        self
            .navigationDestination(for: TelegramChat.self) { NChatAudioView(chat: $0) }
            .navigationDestination(for: Playlist.self) { NPlaylistDetailView(playlist: $0) }
            .navigationDestination(for: Artist.self) { NArtistView(artist: $0) }
            .navigationDestination(for: UserProfilePlaylist.self) { NProfilePlaylistDetailView(profile: $0) }
    }
}

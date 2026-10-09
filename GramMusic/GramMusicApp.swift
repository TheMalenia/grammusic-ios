import SwiftUI
import SwiftData
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseCrashlytics)
import FirebaseCrashlytics
#endif

@main
struct GramMusicApp: App {

    @State private var telegram: TelegramService
    @State private var player: PlayerEngine
    @State private var settings = AppSettings()         // Nocturne design system
    @State private var importStore: ImportStore         // imported-chats onboarding state

    let modelContainer: ModelContainer

    init() {
        #if canImport(FirebaseCore)
        // Personal builds run without analytics unless their own Firebase config is bundled.
        if Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil {
            FirebaseApp.configure()
        }
        #endif

        // Build the SwiftData stack. A corrupt or migration-incompatible store used to be a
        // `fatalError` here — an unrecoverable launch crash loop whose only user-side remedy was
        // deleting the app. Instead: rebuild the store from scratch (playlists are local state and
        // the smart ones are recreated lazily), and as a last resort fall back to in-memory so the
        // app still launches and can play music.
        modelContainer = Self.makeModelContainer()

        // Create the Telegram service exactly once and share it with the player. Creating
        // it twice (once here, once via a property default) would spin up two TDLib clients
        // on the same database directory — which crashes on launch with the real backend.
        let telegramService = TelegramService.makeDefault()
        // Let the service record auto-downloads into the "Downloaded" playlist and seed the
        // downloaded set from it on launch.
        telegramService.attachModelContext(modelContainer.mainContext)
        _telegram = State(initialValue: telegramService)
        let engine = PlayerEngine(
            fileProvider: { track in try await telegramService.localFile(for: track) },
            itemProvider: { track in try await telegramService.playerItem(for: track) },
            artworkProvider: { track in await telegramService.highResArtwork(for: track) }
        )
        // Fires only once a track has genuinely been listened to — a skipped track is not recorded.
        engine.onTrackStarted = { track in
            telegramService.recordRecent(track)
            AnalyticsService.logPlayTrack()
        }
        let playlistContext = modelContainer.mainContext
        engine.onSearchTrackListened = { track in
            PlaylistService(context: playlistContext).recordSearchListen(track,
                enabled: UserDefaults.standard.bool(forKey: StorageKeys.saveSearchResults))
        }
        // The engine declares what playback needs, in order (playing track, next, lookahead) and
        // the service schedules it. Fires on every load and queue edit, before the listen
        // threshold, so downloads re-aim the moment the queue moves.
        engine.onDownloadPlanChanged = { plan in
            telegramService.planPlaybackDownloads(plan)
        }
        // Offline, un-downloaded tracks can't stream — the player hops over them and brings them
        // back once online (the queue is preserved).
        // `isAvailableOffline`, not `isDownloaded`: a cached track is a real file on disk and plays
        // with no network, so the player must not hop over it offline.
        engine.isUnavailableOffline = { track in
            telegramService.isHidden(track) || (telegramService.isOffline && !telegramService.isAvailableOffline(track))
        }
        engine.unavailableQueueNotice = { tracks in
            if !tracks.isEmpty && tracks.allSatisfy(telegramService.isHidden) {
                return String(localized: "These songs are hidden. Unhide them to play again.")
            }
            return String(localized: "Not downloaded — connect to the internet to play these.")
        }
        telegramService.onTracksHidden = { [weak engine] ids in engine?.removeHiddenTracks(ids) }
        // Keep playing when the queue runs out rather than falling silent — related music online,
        // downloaded music offline. Returns [] when there's nothing, and the engine then loops the
        // queue it already has.
        engine.autoplayProvider = { seed, exclude in
            telegramService.autoplayCandidates(seed: seed, excluding: exclude)
        }
        // State that outlives the account otherwise: on a sign-out — deliberate *or* forced from
        // another device — playback would keep running with the mini-player docked over the login
        // screen holding the previous account's tracks, and the imported-chat selection would
        // carry over to whoever signs in next.
        let imports = ImportStore()
        _importStore = State(initialValue: imports)
        telegramService.onSessionEnded = { [weak engine] in
            engine?.stop()
            imports.clear()
        }
        // Blocking a source has to take effect in the player too, not just in the lists — see
        // `TelegramService+Moderation`. The service can't reach into the engine itself, so the
        // dependency is injected here the same way `onSessionEnded` is.
        telegramService.onContentBlocked = { [weak engine] blocked in
            engine?.removeBlockedSources(blocked)
        }
        // Leaving a channel takes it out of the Library immediately rather than at the next
        // chat-list refresh, which is rate-limited to minutes.
        telegramService.onChatLeft = { chatId in
            imports.hideChat(chatId)
        }
        engine.restoreState()   // bring back the last queue + position (paused) on launch
        _player = State(initialValue: engine)
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NocturneRootView()
                .environment(telegram)
                .environment(player)
                .environment(settings)
                .environment(importStore)
                .onOpenURL { url in
                    handleURL(url)
                }
                .task {
                    telegram.bootstrap()
                    telegram.syncRecentlyPlayedToWidget()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        telegram.syncRecentlyPlayedToWidget()
                    case .inactive, .background:
                        // Both of these are written on a trailing debounce while the app runs, so
                        // going away is the moment they have to actually hit disk. `flushPlayCounts`
                        // documented this as its backgrounding path but nothing ever called it.
                        telegram.flushPlayCounts()
                        player.flushState()
                    @unknown default:
                        break
                    }
                }
        }
        .modelContainer(modelContainer)
    }

    /// Three-step degradation so a bad store can never brick the app:
    /// open normally → wipe and rebuild on disk → in-memory.
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([Playlist.self, TrackRef.self])
        do {
            return try ModelContainer(for: schema)
        } catch {
            log.error("ModelContainer failed, rebuilding store: \(error.localizedDescription, privacy: .public)")
        }

        // The default store lives in Application Support; remove it and try once more.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            try? FileManager.default.removeItem(at: support.appendingPathComponent(name))
        }
        do {
            return try ModelContainer(for: schema)
        } catch {
            log.error("ModelContainer rebuild failed, falling back to in-memory: \(error.localizedDescription, privacy: .public)")
        }

        do {
            return try ModelContainer(for: schema,
                                      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch {
            // An in-memory container cannot realistically fail; if it does the process is unusable.
            fatalError("Failed to create even an in-memory ModelContainer: \(error)")
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "grammusic" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if url.host == "play" || url.path.contains("play") {
            if let trackId = components?.queryItems?.first(where: { $0.name == "id" })?.value {
                let recents = telegram.recentlyPlayed
                if let idx = recents.firstIndex(where: { $0.remoteUniqueId == trackId || $0.id == trackId }) {
                    player.play(tracks: recents, startAt: idx, context: "Recently Played")
                }
            }
        }
    }
}

import Foundation
import Observation
import AVFoundation
import SwiftData
import WidgetKit
import UIKit
import os

/// App-wide logger. View live in Xcode's console, or in Console.app / `log stream`
/// by filtering subsystem "GramMusic" (category "download" for the download path).
let log = Logger(subsystem: "GramMusic", category: "general")
let downloadLog = Logger(subsystem: "GramMusic", category: "download")

/// Observable facade over a `TelegramBackend`. SwiftUI views observe this; it owns the
/// backend and mirrors its async state onto the main actor.
@MainActor
@Observable
final class TelegramService {

    let searchSources = SearchSourceStore()
    let hiddenTracks: HiddenTracksStore
    @ObservationIgnored var onTracksHidden: ((Set<String>) -> Void)?
    @ObservationIgnored let inlineSearchContext = InlineMusicSearchContext()

    private(set) var authState: TelegramAuthState = .initializing
    private(set) var connectionState: TelegramConnectionState = .connecting
    /// `private(set)` was relaxed to internal for `TelegramService+Moderation`, which must drop
    /// blocked chats out of this list the instant a block happens. Still written only by this file
    /// and that extension.
    var chats: [TelegramChat] = []
    private(set) var userProfiles: [UserProfilePlaylist] = []
    private(set) var isLoadingChats = false
    private(set) var isPreloadingCovers = false
    private(set) var preloadedCoversCount = 0
    private(set) var isInitialDataReady = false
    /// Why the launch sync failed, or `nil`. **Read by `NHomeView`**, which offers a Retry — it
    /// used to be written here and read nowhere, so a failed launch left an endless skeleton.
    private(set) var initialSyncError: String?
    private(set) var isInitialSyncInProgress = false
    @ObservationIgnored private var initialSyncRetries = 0
    @ObservationIgnored nonisolated(unsafe) private var initialSyncRetryTask: Task<Void, Never>?
    
    var passwordHint: String? { authState.passwordHint }
    var codeInfo: TelegramCodeInfo? { authState.codeInfo }
    
    var downloadingIds: Set<String> = []
    /// Tracks the user **explicitly downloaded**. These are permanent, never evicted, and are what
    /// the "Downloaded" library and every download checkmark show.
    var downloadedIds: Set<String> = []
    /// Tracks whose audio is on disk because they were *played*. Real files — they play offline
    /// exactly like a download — but they live under a byte budget and are evicted
    /// least-recently-played first (`AudioCacheLedger`). Kept apart from `downloadedIds` so that
    /// merely listening never silently fills the user's phone under the label "Downloaded".
    var cachedIds: Set<String> = []
    /// The on-disk audio store's policy: what may be evicted, and when.
    @ObservationIgnored let audioCache = AudioCacheLedger()
    /// The tracks playback last asked for (playing + lookahead). Protected from cache eviction
    /// even after their downloads finish — see `cacheProtectedKeys`.
    @ObservationIgnored var playbackPlanKeys: Set<String> = []

    /// **Keep everything I play** (Settings ▸ Storage). **On by default.**
    ///
    /// When on, a track that finishes downloading because it was played is treated exactly as if
    /// the user had tapped Download: it moves into the Downloaded library and stops being
    /// evictable. Turning it *off* hands played tracks to `AudioCacheLedger` instead — still
    /// playable offline, but under a budget and an age limit.
    ///
    /// Read with `object(forKey:) as? Bool ?? true`, **not** `bool(forKey:)`: the latter returns
    /// `false` for a key that was never written, which would silently make the default off.
    var autoDownloadPlayed: Bool = UserDefaults.standard.object(forKey: StorageKeys.autoDownload) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoDownloadPlayed, forKey: StorageKeys.autoDownload)
            if autoDownloadPlayed { promoteCachedToDownloads() }
        }
    }
    /// Track IDs that were explicitly requested for download by the user (e.g. Download All, or manual Download button).
    /// These are protected from auto-cancellation when the user skips or changes tracks during playback.
    var explicitDownloadIds: Set<String> = []
    /// Tracks that have been deleted on Telegram and cannot be streamed or downloaded from the server.
    private(set) var unavailableTrackIds: Set<String> = []
    /// Live download fraction (0…1) per `remoteUniqueId`, driving the filling-circle UI.
    var downloadProgressByTrack: [String: Double] = [:]
    /// Favourited track ids, mirroring the Favorites playlist.
    ///
    /// Favourite state used to be read straight from SwiftData and copied into each view's
    /// `@State` on `onAppear`. That meant a fetch per view, and — because nothing told the other
    /// surfaces — liking a track in Now Playing left the same track's row elsewhere showing the
    /// old state until it happened to be rebuilt. Held here (same shape as `downloadedIds`) it is
    /// observable, so every surface updates together and rows never touch the database.
    /// Chats the user has blocked. Authoritative for what the app will display — see
    /// `TelegramService+Moderation` for why the local list, not Telegram's, is the source of
    /// truth. Written by that extension; a stored property, so it cannot live there.
    var blockedChatIds: Set<Int64> = []

    /// Titles for blocked chats, kept so Settings ▸ Blocked can name them. Blocking removes a chat
    /// from `chats`, so by the time the list is drawn there is nothing left to look the name up in.
    var blockedTitles: [Int64: String] = [:]

    /// Called when content is blocked, with the blocked chat ids — wired in `GramMusicApp` to
    /// evict those tracks from the play queue. Blocking the song that is currently playing has to
    /// stop it playing; the service must not reach into `PlayerEngine` to do that itself.
    @ObservationIgnored var onContentBlocked: ((Set<Int64>) -> Void)?

    /// Called when the user leaves a channel or group, with its chat id — wired in `GramMusicApp`
    /// to hide it in `ImportStore`. The service owns neither the import store nor the player, so
    /// both effects are injected rather than reached for.
    @ObservationIgnored var onChatLeft: ((Int64) -> Void)?

    private(set) var favoriteIds: Set<String> = []
    var lastError: String?

    /// Artists the user follows (performer names), newest first.
    private(set) var followedArtists: [String] = []
    private let artistsKey = StorageKeys.followedArtists
    
    /// Per-artist play tally derived from `playCounts`. Cached because `sortedFollowedArtists` is
    /// read from view bodies: rebuilding it (a full pass over every played track) on every render
    /// was pure waste. Invalidated by `bumpPlayCount`.
    @ObservationIgnored private var artistPlayCountsCache: [String: Int]?

    private var artistPlayCounts: [String: Int] {
        if let cached = artistPlayCountsCache { return cached }
        var counts: [String: Int] = [:]
        for (key, count) in playCounts {
            if let track = playedTracks[key], !track.performer.isEmpty {
                counts[track.performer.lowercased(), default: 0] += count
            }
        }
        artistPlayCountsCache = counts
        return counts
    }

    var sortedFollowedArtists: [String] {
        let counts = artistPlayCounts
        // Precompute follow order once instead of an O(n) firstIndex inside the comparator.
        let order = Dictionary(followedArtists.enumerated().map { ($1, $0) },
                               uniquingKeysWith: { a, _ in a })
        return followedArtists.sorted { a, b in
            let countA = counts[a.lowercased()] ?? 0
            let countB = counts[b.lowercased()] ?? 0
            if countA != countB { return countA > countB }
            return (order[a] ?? 0) < (order[b] ?? 0)
        }
    }
    
    /// Ordered keys of items pinned to the top of the Library, across kinds. Keys are stable
    /// across launches: `"p:<name>"` (playlist), `"c:<id>"` (chat), `"a:<lowercased name>"`
    /// (artist). Order in this array *is* the user's pin order (drag-to-reorder rewrites it).
    private(set) var pinnedKeys: [String] = []
    private let pinnedKey = StorageKeys.pinnedKeys

    /// Per-entry "last opened" timestamps for the Library's **Recents** sort, keyed by the same
    /// stable `pinKey` namespace as `pinnedKeys` (`p:`/`a:`/`c:`). Updated when the user taps into
    /// a playlist/artist/chat; entries with no entry here sort below the opened ones.
    private(set) var lastOpened: [String: Date] = [:]
    private let lastOpenedKey = StorageKeys.lastOpened
    /// Keys whose default-pin has already been applied once (so unpinning them sticks).
    private let seededPinsKey = StorageKeys.seededPins
    /// Internal rather than `private(set)` so the moderation extension can purge blocked sources
    /// from it — see `TelegramService+Moderation`.
    var recentlyPlayed: [AudioTrack] = []
    private let recentKey = StorageKeys.recentlyPlayed
    /// All-time play counts keyed by `remoteUniqueId`, plus the slim track for each, so the Home
    /// "On repeat" shelf can rank the user's most-played songs. Persisted to UserDefaults.
    private(set) var playCounts: [String: Int] = [:]
    @ObservationIgnored private var playedTracks: [String: AudioTrack] = [:]
    private let playCountsKey = StorageKeys.playCounts
    private let playedTracksKey = StorageKeys.playedTracks
    /// Last-seen audio lists per chat / per artist, persisted so a detail screen opens with its
    /// previous contents instantly when offline (then refreshes if a live fetch succeeds).
    @ObservationIgnored var chatAudioCache: [Int64: [AudioTrack]] = [:]
    @ObservationIgnored var artistAudioCache: [String: [AudioTrack]] = [:]
    private let chatAudioKey = StorageKeys.chatAudioCache
    private let artistAudioKey = StorageKeys.artistAudioCache
    /// Logged-in user's profile for the Settings header (loaded lazily once ready).
    private(set) var account: TelegramAccount?

    /// `var`, not `let`, solely so `enterDemoMode()` can swap in `MockTelegramBackend` for the
    /// App Review demo login. Never reassigned during normal operation.
    var backend: TelegramBackend
    /// True while running on the offline demo backend (see `AppConfig.demoPhoneNumber`).
    private(set) var isDemoMode: Bool
    @ObservationIgnored nonisolated(unsafe) private var observationTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var connectionTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var progressTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var chatListUpdateTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var accountUpdateTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var blockListTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var deletionTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var chatRefreshTask: Task<Void, Never>?
    /// Loads the large on-disk audio caches off the launch path (see `init`).
    @ObservationIgnored nonisolated(unsafe) private var loadAudioCachesTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var loadUserProfilesTask: Task<Void, Never>?
    /// Trailing debounce for the play-count / played-track persistence. Both dictionaries were
    /// re-encoded into UserDefaults synchronously on every single play.
    @ObservationIgnored nonisolated(unsafe) private var persistPlaysTask: Task<Void, Never>?
    /// SwiftData context for recording auto-downloads into the "Downloaded" smart playlist.
    /// Attached once from the app (`attachModelContext`); the views' own `PlaylistService` is
    /// unaffected.
    @ObservationIgnored var modelContext: ModelContext?
    /// Tracks currently being fetched (explicitly or by playback), so a completion event —
    /// which only carries a `remoteUniqueId` — can be recorded into the Downloaded playlist
    /// with the full track metadata.
    @ObservationIgnored var activeDownloadTracks: [String: AudioTrack] = [:]
    /// Cancellable handles for in-flight explicit downloads, so Stop can actually halt them.
    @ObservationIgnored nonisolated(unsafe) var downloadTasks: [String: Task<Void, Never>] = [:]
    /// Keys the user just cancelled — late progress updates for them are swallowed so the
    /// download doesn't "come back" (TDLib emits a few more `updateFile`s after `deleteFile`).
    @ObservationIgnored var canceledDownloadIds: Set<String> = []
    /// Insertion order for `canceledDownloadIds`, so the set can be bounded (see `noteCanceled`).
    @ObservationIgnored var canceledDownloadOrder: [String] = []
    static let maxCanceledDownloadMemory = 300
    
    @ObservationIgnored private var chatMessageCache: [Int64: [ChatMessage]] = [:]
    
    /// Decides what downloads next and what a failure means. Pure and unit-tested; this class
    /// only drives it (see `TelegramService+Downloads`).
    @ObservationIgnored let downloads = DownloadScheduler(maxConcurrent: 3, maxPlaybackLane: 2)
    /// Wakes `processDownloadQueue()` when a backed-off retry becomes eligible.
    @ObservationIgnored nonisolated(unsafe) var downloadRetryTask: Task<Void, Never>?

    /// `isOffline` that has held for a couple of seconds — what the **UI** uses (offline bar,
    /// dimmed rows) so a normal startup's brief `connecting` phase doesn't flash "You're offline".
    /// Lives here because extensions can't hold stored properties; the logic that maintains it is
    /// in TelegramService+Profile.swift.
    /// Which tracks are on the user's Telegram profile, mirrored the way `favoriteIds` is.
    /// `isProfileAudio` used to run a SwiftData fetch plus a linear scan of the playlist's
    /// relationship *per call* — and it is called once per row inside Now Playing's queue ForEach.
    private(set) var profileIds: Set<String> = []

    /// Rebuild `profileIds` from the Profile Music playlist. Cheap; call after any profile write.
    func refreshProfileIds() {
        guard let context = modelContext,
              let profile = PlaylistService(context: context).existingProfile() else {
            profileIds = []
            return
        }
        profileIds = Set(profile.tracks.map(\.remoteUniqueId))
    }

    /// Membership of the app's own Telegram channel (`AppConfig.communityChannelUsername`).
    /// Starts `.unknown` and is filled in by `refreshCommunityMembership()`; the join prompt
    /// and the Settings row read it. Logic lives in TelegramService+Community.swift.
    var communityMembership: ChannelMembership = .unknown
    /// True while a join is in flight, so the button can show a spinner and not fire twice.
    var isJoiningCommunity = false

    var isOfflineStable = false
    @ObservationIgnored nonisolated(unsafe) var offlineDebounce: Task<Void, Never>?

    /// A background download failed. Deliberately **not** `lastError`: that one is read by the
    /// playback error banner, so a failed download of some unrelated track used to raise what
    /// looks like a playback failure over Now Playing while the music was playing perfectly well.
    /// Nothing about a download failure should touch the player.
    var downloadError: String?

    /// Tiered resolvers for a track's cacheable attributes — each owns its memory + disk tier,
    /// miss-tracking and in-flight coalescing (see `Resolver`). The versioned disk namespaces all
    /// live together in `ArtworkDiskCache`. The cover surface is *two* resolvers: a `final` cover
    /// (iTunes/embedded, never improves) and a `provisional` Telegram thumbnail shown until it,
    /// with the every-lookup embedded retry composed on top in `highResArtwork`.
    /// Memory budgets are sized to the tier: full-res covers dominate, Telegram thumbnails
    /// (~320px) and chat photos are small. Everything stays on disk, so an eviction costs one
    /// disk read — never a re-fetch from iTunes.
    // Budgets are deliberately modest: every tier is disk-backed, so an eviction costs one cheap
    // file read rather than a refetch. These used to total 44 MB of resident cover bytes.
    @ObservationIgnored private let finalCover = Resolver<Data>.data(store: ArtworkDiskCache.covers, tracksMisses: true, memoryLimit: 12 * 1024 * 1024)
    @ObservationIgnored let provisionalCover = Resolver<Data>.data(store: ArtworkDiskCache.thumbs, tracksMisses: false, memoryLimit: 4 * 1024 * 1024)
    @ObservationIgnored private let chatPhotoCache = Resolver<Data>.data(store: ArtworkDiskCache.photos, tracksMisses: false, memoryLimit: 3 * 1024 * 1024)
    /// **Final** artist portraits only — a real iTunes artist photo (never improves). The
    /// track-derived fallback is *not* cached here: it re-reads its representative track's current
    /// cover on every lookup so the avatar upgrades when that cover does (iTunes/embedded/download).
    @ObservationIgnored private let artistCover = Resolver<Data>.data(store: ArtworkDiskCache.artists, tracksMisses: true, memoryLimit: 4 * 1024 * 1024)
    @ObservationIgnored private var fastArtistCoverCache: [String: Data] = [:]
    @ObservationIgnored private var isArtistCoverHighRes: [String: Bool] = [:]
    /// The representative track chosen once per artist (lowercased name → track), so the derived
    /// avatar stays stable within a session while still reflecting that track's latest cover.
    @ObservationIgnored private var artistRepTrack: [String: AudioTrack] = [:]
    @ObservationIgnored private let lyricsResolver = LyricsResolver(store: ArtworkDiskCache.lyrics)

    private let countKey = StorageKeys.audioCountCache
    struct AudioChatMeta: Codable, Sendable {
        var count: Int
        var lastDate: Date?
        /// When this chat was last probed. Lets `probeAudioCounts` skip chats it already counted
        /// recently instead of re-hitting the network for every chat on every chat-list update.
        var probedAt: Date?
    }

    /// How long a probed audio count stays fresh. Telegram emits chat-list updates constantly;
    /// re-probing up to 1000 chats each time was a serious battery and network drain.
    private static let audioCountTTL: TimeInterval = 10 * 60

    @ObservationIgnored private var countCache: [Int64: AudioChatMeta] = [:]
    init(backend: TelegramBackend, hiddenTracks: HiddenTracksStore? = nil) {
        self.hiddenTracks = hiddenTracks ?? HiddenTracksStore()
        self.backend = backend
        // Demo mode is the *persisted* flag, not "the backend is a mock" — plain mock development
        // mode is also a mock, and conflating the two made `enterDemoMode()` short-circuit and
        // never persist the flag.
        self.isDemoMode = AppConfig.isDemoModeActive
        // Before anything else reads it: `recentlyPlayed` is filtered through `visible(_:)` a few
        // lines down, and a block list loaded *after* that would let blocked tracks back onto the
        // Home shelf for one launch.
        loadBlockList()
        followedArtists = UserDefaults.standard.stringArray(forKey: artistsKey) ?? []
        pinnedKeys = (UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []).deduped()
        if let stored = UserDefaults.standard.dictionary(forKey: lastOpenedKey) as? [String: Double] {
            lastOpened = stored.mapValues { Date(timeIntervalSince1970: $0) }
        }
        if let data = UserDefaults.standard.data(forKey: countKey),
           let decoded = try? JSONDecoder().decode([String: AudioChatMeta].self, from: data) {
            countCache = Dictionary(uniqueKeysWithValues: decoded.compactMap { k, v in
                Int64(k).map { ($0, v) }
            })
        }
        let groupDefaults = UserDefaults(suiteName: "group.com.grammusic.app")
        if let data = groupDefaults?.data(forKey: recentKey) ?? UserDefaults.standard.data(forKey: recentKey),
           let decoded = try? JSONDecoder().decode([AudioTrack].self, from: data) {
            // TDLib file ids are session-scoped: a stored positive fileId from the last
            // launch is garbage now and would skip the remoteFileId re-resolution in the
            // backend. Reset to -1 so playback resolves offline via getRemoteFile.
            recentlyPlayed = visible(decoded.map { $0.rehydratedForOfflineResolution() })
            groupDefaults?.set(data, forKey: recentKey)
            WidgetCenter.shared.reloadAllTimelines()
        }
        if let counts = UserDefaults.standard.dictionary(forKey: playCountsKey) as? [String: Int] {
            playCounts = counts
        }
        if let d = UserDefaults.standard.data(forKey: playedTracksKey),
           let decoded = try? JSONDecoder().decode([String: AudioTrack].self, from: d) {
            playedTracks = decoded.mapValues { $0.rehydratedForOfflineResolution() }
        }
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AudioCaches")
        let chatAudioURL = cacheDir.appendingPathComponent("n_chatAudioCache.json")
        let artistAudioURL = cacheDir.appendingPathComponent("n_artistAudioCache.json")
        let userProfilesURL = cacheDir.appendingPathComponent("n_userProfilesCache.json")

        // The per-chat / per-artist audio caches are by far the largest files here (up to 120
        // tracks per entry) and nothing on screen at launch needs them — they back detail screens
        // the user has to navigate to. Read them off the main actor instead of blocking launch.
        // `chats` below *is* read synchronously: it drives the first frame, and is small.
        loadAudioCachesTask = Task { @MainActor [weak self] in
            let loaded: ([Int64: [AudioTrack]], [String: [AudioTrack]]) = await Task.detached(priority: .userInitiated) {
                var chatCache: [Int64: [AudioTrack]] = [:]
                var artistCache: [String: [AudioTrack]] = [:]
                if let d = try? Data(contentsOf: chatAudioURL),
                   let decoded = try? JSONDecoder().decode([String: [AudioTrack]].self, from: d) {
                    chatCache = Dictionary(uniqueKeysWithValues: decoded.compactMap { k, v in
                        Int64(k).map { ($0, v) }
                    })
                }
                if let d = try? Data(contentsOf: artistAudioURL),
                   let decoded = try? JSONDecoder().decode([String: [AudioTrack]].self, from: d) {
                    artistCache = decoded
                }
                return (chatCache, artistCache)
            }.value
            guard let self else { return }
            // Don't clobber anything a live fetch already wrote while we were loading.
            self.chatAudioCache.merge(loaded.0) { current, _ in current }
            self.artistAudioCache.merge(loaded.1) { current, _ in current }
        }
        // Legacy UserDefaults-backed copies of the same caches (pre-file migration).
        UserDefaults.standard.removeObject(forKey: chatAudioKey)
        UserDefaults.standard.removeObject(forKey: artistAudioKey)

        let chatsURL = cacheDir.appendingPathComponent("n_chatsCache.json")
        if let d = try? Data(contentsOf: chatsURL),
           let decoded = try? JSONDecoder().decode([TelegramChat].self, from: d) {
            chats = decoded
        }
        // `userProfiles` is deferred with the audio caches: each entry embeds up to 50 full
        // AudioTracks, and the decode was followed by a full copy of every one of them. Nothing
        // on the first frame needs it — it feeds the Library/Home profile shelves.
        loadUserProfilesTask = Task { @MainActor [weak self] in
            let loaded: [UserProfilePlaylist] = await Task.detached(priority: .userInitiated) {
                guard let d = try? Data(contentsOf: userProfilesURL),
                      let decoded = try? JSONDecoder().decode([UserProfilePlaylist].self, from: d)
                else { return [] }
                return decoded.map { profile in
                    var p = profile
                    p.tracks = profile.tracks.map { $0.rehydratedForOfflineResolution() }
                    return p
                }
            }.value
            guard let self, self.userProfiles.isEmpty, !loaded.isEmpty else { return }
            self.userProfiles = loaded
        }
        
        // Auto-migrate session state on app updates: if cached chats or audio exist from a previous version,
        // mark initial sync as already completed so the user is never stuck on a black screen or loader.
        if UserDefaults.standard.object(forKey: StorageKeys.hasCompletedInitialSync) == nil {
            if !chats.isEmpty || !chatAudioCache.isEmpty {
                UserDefaults.standard.set(true, forKey: StorageKeys.hasCompletedInitialSync)
            }
        }
    }

    // MARK: - Offline audio-list cache

    private func saveChatsCache() {
        let currentChats = self.chats
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AudioCaches/n_chatsCache.json")
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(currentChats) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func saveUserProfilesCache() {
        let profiles = userProfiles
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AudioCaches/n_userProfilesCache.json")
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(profiles) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func cachedChatAudio(_ chatId: Int64, includeHidden: Bool = false) -> [AudioTrack] {
        guard !blockedChatIds.contains(chatId) else { return [] }
        let tracks = chatAudioCache[chatId] ?? []
        return includeHidden ? tracks : visible(tracks)
    }

    private func persistChatAudioCache() {
        let s = Dictionary(uniqueKeysWithValues: chatAudioCache.map { (String($0.key), $0.value) })
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AudioCaches/n_chatAudioCache.json")
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(s) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func cacheChatAudio(_ tracks: [AudioTrack], chatId: Int64) {
        for track in tracks { unavailableTrackIds.remove(track.remoteUniqueId) }
        chatAudioCache[chatId] = tracks.prefix(120).map(Self.slimForCache)
        persistChatAudioCache()
    }

    func cachedArtistTracks(_ name: String) -> [AudioTrack] { visible(artistAudioCache[name.lowercased()] ?? []) }

    func cacheArtistTracks(_ tracks: [AudioTrack], name: String) {
        for track in tracks { unavailableTrackIds.remove(track.remoteUniqueId) }
        artistAudioCache[name.lowercased()] = tracks.prefix(120).map(Self.slimForCache)
        let s = artistAudioCache
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AudioCaches/n_artistAudioCache.json")
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(s) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
    }
    
    func cachedMessages(_ chatId: Int64) -> [ChatMessage] { chatMessageCache[chatId] ?? [] }
    
    func cacheMessages(_ messages: [ChatMessage], chatId: Int64) {
        chatMessageCache[chatId] = messages
    }

    // MARK: - Cache Management

    /// Calculate total cached bytes on disk across artwork, lyrics, audio JSON caches, and URLCache.
    /// Sum the on-disk caches. The helpers are `nonisolated static` but were called
    /// *synchronously* from this `@MainActor` type, so the recursive directory walk and a
    /// `resourceValues` call per file ran on the main thread — a visible hitch when
    /// Settings ▸ Storage opens with thousands of cached covers.
    func calculateTotalCacheBytes() async -> Int64 {
        let onDisk = await Task.detached(priority: .utility) { () -> Int64 in
            let artworkBytes = ArtworkDiskCache.totalArtworkCacheBytes()
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let audioCachesDir = cachesDir.appendingPathComponent("AudioCaches", isDirectory: true)
            return artworkBytes + ArtworkDiskCache.directorySize(at: audioCachesDir)
        }.value
        return onDisk + Int64(URLCache.shared.currentDiskUsage)
    }

    /// Clear all caches on disk and in memory (artwork, thumbnails, photos, artist covers, lyrics, audio caches, and URL cache)
    /// without removing downloaded tracks or user playlists.
    func clearAllCaches() async {
        await finalCover.clear()
        await provisionalCover.clear()
        await chatPhotoCache.clear()
        await artistCover.clear()
        await lyricsResolver.clear()
        
        chatAudioCache = [:]
        artistAudioCache = [:]
        artistRepTrack = [:]
        chatMessageCache = [:]
        
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let audioCachesDir = cachesDir.appendingPathComponent("AudioCaches")
        try? FileManager.default.removeItem(at: audioCachesDir)
        
        URLCache.shared.removeAllCachedResponses()
    }

    /// Strip per-session/heavy fields so the cache stays small and re-resolves offline on reload.
    private static func slimForCache(_ t: AudioTrack) -> AudioTrack {
        var c = t.rehydratedForOfflineResolution()
        c.artworkData = nil
        return c
    }

    /// Write `recentlyPlayed` out to defaults + the widget's App Group. Split out of
    /// `recordRecent` so the moderation purge can persist a *shortened* list without pretending a
    /// track was just played.
    func persistRecentlyPlayed() {
        guard let data = try? JSONEncoder().encode(recentlyPlayed) else { return }
        UserDefaults.standard.set(data, forKey: recentKey)
        UserDefaults(suiteName: "group.com.grammusic.app")?.set(data, forKey: recentKey)
        syncRecentlyPlayedToWidget()
    }

    /// Flush the per-chat and per-artist listing caches to disk after a purge, so blocked content
    /// does not come back when the caches are reloaded at next launch.
    func persistListingCaches() {
        let chatSnapshot = chatAudioCache
        let artistSnapshot = artistAudioCache
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioCaches")
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(chatSnapshot) {
                try? data.write(to: dir.appendingPathComponent("n_chatAudioCache.json"))
            }
            if let data = try? JSONEncoder().encode(artistSnapshot) {
                try? data.write(to: dir.appendingPathComponent("n_artistAudioCache.json"))
            }
        }
    }

    /// Record a track in the recently-played list (most recent first, de-duplicated, capped).
    func recordRecent(_ track: AudioTrack) {
        var slim = track
        slim.artworkData = nil   // keep the stored list small
        recentlyPlayed.removeAll { $0.remoteUniqueId == slim.remoteUniqueId }
        recentlyPlayed.insert(slim, at: 0)
        if recentlyPlayed.count > 30 { recentlyPlayed = Array(recentlyPlayed.prefix(30)) }
        if let data = try? JSONEncoder().encode(recentlyPlayed) {
            UserDefaults.standard.set(data, forKey: recentKey)
            UserDefaults(suiteName: "group.com.grammusic.app")?.set(data, forKey: recentKey)
        }
        syncRecentlyPlayedToWidget()
        bumpPlayCount(slim)
    }

    @ObservationIgnored private var isSyncingWidget = false
    /// A sync was requested while one was already running — run once more when it finishes rather
    /// than dropping the request, which used to leave the widget permanently stale.
    @ObservationIgnored private var widgetSyncPending = false

    /// Sync the top 8 recent tracks with thumbnails into shared App Group disk container & defaults for the widget.
    func syncRecentlyPlayedToWidget() {
        guard !isSyncingWidget else { widgetSyncPending = true; return }
        isSyncingWidget = true
        Task { @MainActor in
            defer {
                self.isSyncingWidget = false
                if self.widgetSyncPending {
                    self.widgetSyncPending = false
                    self.syncRecentlyPlayedToWidget()
                }
            }
            let top8 = Array(recentlyPlayed.prefix(8))
            var widgetTracks: [WidgetSharedTrack] = []
            var thumbnails: [String: Data] = [:]

            for track in top8 {
                var artData: Data? = track.artworkData
                if artData == nil {
                    artData = await ArtworkDiskCache.covers.data(for: track.remoteUniqueId)
                }
                if artData == nil {
                    artData = await ArtworkDiskCache.thumbs.data(for: track.remoteUniqueId)
                }
                if artData == nil {
                    artData = await highResArtwork(for: track)
                }
                var thumbData: Data? = nil
                if let art = artData {
                    // Decode straight to 100px instead of materialising the full ~1000px bitmap
                    // and drawing it down — eight covers used to peak around 32 MB of transient
                    // memory, all of it on the main actor.
                    let jpeg = await Task.detached(priority: .utility) {
                        ImageDownsampling.jpegThumbnail(from: art, maxPixel: 200, compression: 0.65)
                    }.value
                    if let jpeg {
                        thumbData = jpeg
                        thumbnails[track.remoteUniqueId] = jpeg
                    }
                }
                widgetTracks.append(WidgetSharedTrack(
                    id: track.remoteUniqueId,
                    title: track.displayTitle,
                    artist: track.displaySubtitle,
                    artworkData: thumbData
                ))
            }

            WidgetSharedStore.saveTracks(widgetTracks, thumbnails: thumbnails)
            WidgetCenter.shared.reloadAllTimelines()
            WidgetCenter.shared.reloadTimelines(ofKind: "RecentlyPlayedWidget")
        }
    }

    /// How many played tracks we keep counts for. The "On repeat" shelf only shows ~12, and both
    /// dictionaries are re-encoded into UserDefaults on *every* play — unbounded growth made that
    /// write progressively more expensive and eventually bloated the defaults plist.
    private static let maxTrackedPlays = 300

    /// Increment the all-time play count for a track and persist it (feeds the "On repeat" shelf).
    private func bumpPlayCount(_ slim: AudioTrack) {
        let key = slim.remoteUniqueId
        playCounts[key, default: 0] += 1
        playedTracks[key] = slim
        if playCounts.count > Self.maxTrackedPlays { prunePlayCounts() }
        artistPlayCountsCache = nil   // invalidate the derived per-artist tally
        schedulePlayCountPersist()
    }

    /// Coalesce play-count writes. Encoding up to 300 tracks and writing them to UserDefaults ran
    /// synchronously on the main actor on *every* track start; nothing reads these back until the
    /// next launch, so a trailing write is enough. `flushPlayCounts()` covers backgrounding.
    private func schedulePlayCountPersist() {
        persistPlaysTask?.cancel()
        persistPlaysTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.flushPlayCounts()
        }
    }

    /// Write the play history now. Called on a trailing debounce and when the app backgrounds.
    func flushPlayCounts() {
        persistPlaysTask?.cancel()
        persistPlaysTask = nil
        let counts = playCounts
        let tracks = playedTracks
        let countsKey = playCountsKey
        let tracksKey = playedTracksKey
        UserDefaults.standard.set(counts, forKey: countsKey)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(tracks) {
                UserDefaults.standard.set(data, forKey: tracksKey)
            }
        }
    }

    /// Drop the least-played entries back down to the cap, keeping the tracks that actually feed
    /// the "On repeat" shelf and the artist ranking.
    private func prunePlayCounts() {
        let keep = playCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key > $1.key }
            .prefix(Self.maxTrackedPlays)
        let keptKeys = Set(keep.map(\.key))
        playCounts = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        playedTracks = playedTracks.filter { keptKeys.contains($0.key) }
    }

    /// The user's most-played tracks (count ≥ 2 to be meaningful), most-played first, capped.
    /// Backs the Home "On repeat" shelf. Empty until a few tracks earn repeat plays.
    func topTracks(limit: Int = 12) -> [AudioTrack] {
        playCounts
            .filter { $0.value >= 2 }
            .sorted { 
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key > $1.key // stable tie-breaker so the list doesn't shuffle on its own
            }
            .compactMap { playedTracks[$0.key] }
            .prefix(limit)
            .map { $0 }
    }

    /// More music to keep playing once the queue runs out, for `PlayerEngine.autoplayProvider`.
    ///
    /// **Every candidate is filtered to what can actually play right now** — offline that is the
    /// downloaded set — because handing the player tracks it must then skip over is how the queue
    /// ends up stuck. Sources in order of how related they are to what just finished: more by the
    /// same artist, then the user's most-played, then recently played, then (mostly for the offline
    /// case) anything else in the Downloaded library.
    func autoplayCandidates(seed: AudioTrack?, excluding: Set<String>, limit: Int = 20) -> [AudioTrack] {
        var seen = excluding
        var out: [AudioTrack] = []

        func take(_ tracks: [AudioTrack]) {
            for track in tracks {
                guard out.count < limit else { return }
                // "Keep playing" must not wander back into a blocked source — that would be the
                // app re-introducing, unprompted, exactly the content the user shut off.
                guard !blockedChatIds.contains(track.chatId) else { continue }
                guard !isUnavailableOnTelegram(track), !isHidden(track) else { continue }
                guard !isOffline || isAvailableOffline(track) else { continue }
                guard seen.insert(track.remoteUniqueId).inserted else { continue }
                out.append(track)
            }
        }

        if let performer = seed?.performer, !performer.isEmpty {
            take(cachedArtistTracks(performer))
        }
        take(topTracks(limit: limit))
        take(recentlyPlayed)
        if out.count < limit, let context = modelContext,
           let downloads = PlaylistService(context: context).existingDownloads() {
            take(downloads.orderedTracks.map(\.audioTrack))
        }
        return out
    }

    private func saveCountCache() {
        let serializable = Dictionary(uniqueKeysWithValues: countCache.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(serializable) {
            UserDefaults.standard.set(data, forKey: countKey)
        }
    }

    /// Default wiring chosen by `AppConfig`. A demo session (App Review) is sticky across
    /// relaunches so backgrounding the app doesn't drop the reviewer back to the login screen.
    static func makeDefault() -> TelegramService {
        let backend: TelegramBackend
        if AppConfig.useMockTelegram || AppConfig.isDemoModeActive {
            // Only a *demo* session is sticky; plain mock development mode keeps the login flow.
            // `n_isLoggedIn` is written by this service when auth reaches `.ready`, so it survives
            // a backend swap mid-login — unlike the mock's own key, which does not.
            let signedIn = AppConfig.isDemoModeActive && UserDefaults.standard.bool(forKey: StorageKeys.isLoggedIn)
            backend = MockTelegramBackend(persistsSession: AppConfig.isDemoModeActive,
                                          startsSignedIn: signedIn)
        } else {
            backend = TDLibTelegramBackend()
        }
        return TelegramService(backend: backend)
    }

    var isAuthenticated: Bool { authState == .ready }

    /// Whether the *last known* auth state was signed in — the shell may be shown through the
    /// `.initializing` flash on that basis alone.
    ///
    /// **`n_isLoggedIn` is authoritative and a written `false` is an answer, not a miss.** The
    /// service writes it on every auth transition (true at `.ready`, false at the phone screen),
    /// so once TDLib has spoken even once on this device the flag knows. The on-disk fallback
    /// below is only for installs that predate the flag, and it must never *override* a recorded
    /// `false`: TDLib creates `db.sqlite` the moment its client starts, signed in or not, so
    /// "the database exists" is true on the second launch of an account-less install — which is
    /// how a never-logged-in user was shown the whole signed-in shell until auth caught up, and
    /// how swapping backends (entering demo mode) flashed Home on the way to the code screen.
    var hasCachedSession: Bool {
        if let known = UserDefaults.standard.object(forKey: StorageKeys.isLoggedIn) as? Bool {
            return known
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dbFile = support.appendingPathComponent("tdlib/database/db.sqlite").path
        return FileManager.default.fileExists(atPath: dbFile)
    }

    func bootstrap() {
        syncRecentlyPlayedToWidget()
        guard observationTask == nil else { return }
        startObservers()
        Task { await backend.start() }
    }

    deinit {
        for task in [observationTask, connectionTask, progressTask,
                     chatListUpdateTask, accountUpdateTask, deletionTask, blockListTask,
                     chatRefreshTask, offlineDebounce, downloadRetryTask, initialSyncRetryTask,
                     loadAudioCachesTask, loadUserProfilesTask, persistPlaysTask] {
            task?.cancel()
        }
        for task in downloadTasks.values { task.cancel() }
    }

    /// Cancel every stream mirror. Paired with `startObservers()` when the backend is swapped.
    private func stopObservers() {
        for task in [observationTask, connectionTask, progressTask,
                     chatListUpdateTask, accountUpdateTask, deletionTask, blockListTask] {
            task?.cancel()
        }
        observationTask = nil; connectionTask = nil; progressTask = nil
        chatListUpdateTask = nil; accountUpdateTask = nil; deletionTask = nil; blockListTask = nil
    }

    /// Mirror the current backend's async streams onto main-actor state.
    private func startObservers() {
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await state in self.backend.authStates() {
                let wasSignedIn = self.hasBeenReadyThisSession
                if state != .ready { self.inlineSearchContext.clear() }
                self.authState = state
                if state == .ready {
                    self.hasBeenReadyThisSession = true
                    self.didUserInitiateLogout = false
                    self.sessionExpiredNotice = nil
                    // A *fresh* login (as opposed to a relaunch into an existing session) re-opens
                    // the community invitation. `wipeLocalAccountData()` already clears the flag on
                    // the paths it owns, but not every way into a new session goes through it —
                    // leaving demo mode, or signing in on a device whose defaults outlived the
                    // account. Keying off `n_isLoggedIn` makes "each login asks once" true for all
                    // of them, without nagging on every launch.
                    if !UserDefaults.standard.bool(forKey: StorageKeys.isLoggedIn) {
                        self.resetCommunityPrompt()
                    }
                    UserDefaults.standard.set(true, forKey: StorageKeys.isLoggedIn)
                    await self.performInitialSync()
                } else if state == .waitingForPhoneNumber || state == .closed {
                    // `.closed` is a *recoverable internal* TDLib event — the backend recreates
                    // the client right after. Only the phone screen means the session really
                    // ended, so only that may trigger the destructive remote-sign-out wipe.
                    let isRealSignOut = (state == .waitingForPhoneNumber)
                    UserDefaults.standard.set(false, forKey: StorageKeys.isLoggedIn)
                    self.chats = []
                    self.isInitialDataReady = false
                    self.initialSyncError = nil
                    // Dropped back to the phone screen from a signed-in session that the user
                    // never asked to end → signed out remotely (another device, revoked session).
                    if wasSignedIn, isRealSignOut {
                        self.hasBeenReadyThisSession = false
                        await self.handleRemoteSignOut()
                    }
                }
            }
        }
        connectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await state in self.backend.connectionStates() {
                // Any non-ready → ready transition is a recovery (network returned, or a VPN finally
                // made Telegram reachable) — refresh the profile mirror now that reads/writes work.
                let recovered = self.connectionState != .ready && state == .ready
                self.connectionState = state
                self.refreshOfflineStable()
                if recovered && self.isAuthenticated {
                    if !self.isInitialDataReady {
                        await self.performInitialSync()
                    } else {
                        await self.syncProfileAudio()
                        await self.syncBlockList()
                        // The link is back: clear every download backoff so parked work resumes
                        // at once rather than waiting out a timer set while offline.
                        self.resumeDeferredDownloads()
                    }
                }
            }
        }
        progressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await update in self.backend.downloadProgress() { self.apply(update) }
        }
        chatListUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.backend.chatListUpdates() {
                guard self.authState == .ready else { continue }
                self.handleChatListEvent(event)
            }
        }
        blockListTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await change in self.backend.blockListUpdates() {
                guard self.authState == .ready else { continue }
                self.applyBlockListChange(chatId: change.chatId, isBlocked: change.isBlocked)
            }
        }
        accountUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in self.backend.accountUpdates() {
                guard self.authState == .ready else { continue }
                // Re-fetch the profile whenever TDLib tells us the logged-in user changed.
                self.account = await self.backend.currentAccount()
            }
        }
        deletionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await update in self.backend.deletionUpdates() {
                self.handleDeletionUpdate(chatId: update.chatId, messageIds: update.messageIds)
            }
        }
    }

    // MARK: - Demo mode (App Review)

    /// Swap onto the offline `MockTelegramBackend` for the App Review demo login. Everything from
    /// here on is canned, on-device data — no Telegram network traffic, no real account, and no
    /// session key shipped in the app. Reversed by `logOut()`.
    private func enterDemoMode() async {
        // Persist first and unconditionally: the flag is what makes the session survive relaunch,
        // and it must be written even when a mock backend is already in place (mock development
        // mode), where the old early return skipped it entirely.
        isDemoMode = true
        AppConfig.isDemoModeActive = true
        guard !(backend is MockTelegramBackend) else { return }
        stopObservers()
        backend = MockTelegramBackend(persistsSession: true)
        startObservers()
        await backend.start()
    }

    /// Leave demo mode and restore the real TDLib backend — on log out, and whenever a real
    /// phone number is entered while the mock backend happens to be in place. The start is
    /// awaited (it used to be fire-and-forget) because the very next thing a caller does is
    /// hand the new backend a phone number.
    private func exitDemoMode() async {
        // The backend must actually be the mock: keying this off `isDemoMode` alone could
        // construct a second TDLibTelegramBackend over the live one's database directory.
        guard isDemoMode, !AppConfig.useMockTelegram, backend is MockTelegramBackend else { return }
        stopObservers()
        backend = TDLibTelegramBackend()
        isDemoMode = false
        AppConfig.isDemoModeActive = false
        UserDefaults.standard.removeObject(forKey: StorageKeys.mockSignedIn)
        startObservers()
        await backend.start()
    }

    /// Wait for a freshly-swapped backend to finish starting, so `setPhoneNumber` isn't sent
    /// into a client that is still initializing. Gives up after `timeout` and lets the call
    /// through — a stuck backend surfaces as a normal auth error rather than a hang.
    private func awaitAuthPrompt(timeout: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeout)
        while authState == .initializing, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func handleDeletionUpdate(chatId: Int64, messageIds: [Int64]) {
        let validIds = messageIds.filter { $0 > 0 }
        guard !validIds.isEmpty else { return }
        let deletedSet = Set(validIds)
        if var msgs = chatMessageCache[chatId] {
            msgs.removeAll { deletedSet.contains($0.id) }
            chatMessageCache[chatId] = msgs
        }
        if var cachedTracks = chatAudioCache[chatId] {
            for track in cachedTracks where track.messageId > 0 && deletedSet.contains(track.messageId) {
                if !isAvailableOffline(track) {
                    unavailableTrackIds.insert(track.remoteUniqueId)
                }
            }
            cachedTracks.removeAll { $0.messageId > 0 && deletedSet.contains($0.messageId) }
            chatAudioCache[chatId] = cachedTracks
            persistChatAudioCache()
        }
    }

    /// Longest a pending chat-list refresh may be deferred by further updates.
    ///
    /// A plain trailing debounce **starves**: Telegram trickles chat-list updates continuously on
    /// an active account, and every one of them reset the 2.5s timer, so the refresh could be put
    /// off indefinitely. This is the ceiling — once an update has been waiting this long the
    /// refresh runs regardless of what else arrives.
    private static let chatRefreshMaxWait: TimeInterval = 20
    /// Don't reload the whole chat list more often than this. `loadChats(limit: 1000)` issues one
    /// `getChat` per chat; running it per update burst is minutes of network for nothing.
    private static let chatRefreshTTL: TimeInterval = 3 * 60
    @ObservationIgnored private var lastChatRefreshAt: Date = .distantPast
    /// When the oldest still-unserved chat-list update arrived (`nil` = none pending).
    @ObservationIgnored private var chatRefreshPendingSince: Date?

    /// Route a chat-list update: a chat we have genuinely never seen skips the refresh TTL, and
    /// everything else stays rate-limited.
    ///
    /// The guard matters both ways. Without it, joining a channel did not reach the Library until
    /// `chatRefreshTTL` (three minutes) expired — the user's complaint. With a naive
    /// "`.chatAdded` always forces", launch would be a storm: TDLib emits `updateNewChat` for every
    /// chat it loads, hundreds of them, each one forcing a full 1000-chat reload.
    private func handleChatListEvent(_ event: ChatListEvent) {
        if case .audioAdded(let chatId, let date) = event {
            noteChatAudioActivity(chatId: chatId, date: date)
        }
        if case .chatAdded(let id) = event, isUnseenChat(id) {
            knownChatIds.insert(id)
            chatRefreshTask?.cancel()
            chatRefreshPendingSince = nil
            chatRefreshTask = Task { @MainActor [weak self] in
                // A short settle so joining several chats at once is still one reload.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.refreshChats(force: true)
            }
            return
        }
        triggerChatRefresh()
    }

    /// New audio should rise in Recents even if the chat was opened before it arrived.
    /// Older/replayed events must not move its activity backwards.
    func noteChatAudioActivity(chatId: Int64, date: Date) {
        guard let index = chats.firstIndex(where: { $0.id == chatId }),
              date > (chats[index].lastAudioDate ?? .distantPast) else { return }
        chats[index].lastAudioDate = date
        var meta = countCache[chatId] ?? AudioChatMeta(count: max(1, chats[index].audioCount ?? 0))
        meta.lastDate = date
        meta.probedAt = nil // refresh the exact count while keeping known audio visible
        countCache[chatId] = meta
        saveChatsCache()
        saveCountCache()
    }

    /// Chat ids the app has already accounted for. Seeded from whatever is on screen and in the
    /// count cache, so a relaunch does not treat the entire restored list as newly joined.
    @ObservationIgnored private var knownChatIds: Set<Int64> = []

    private func isUnseenChat(_ id: Int64) -> Bool {
        if knownChatIds.isEmpty {
            knownChatIds = Set(chats.map(\.id)).union(countCache.keys)
        }
        return !knownChatIds.contains(id)
            && !chats.contains { $0.id == id }
            && countCache[id] == nil
    }

    private func triggerChatRefresh() {
        let now = Date()
        if chatRefreshPendingSince == nil { chatRefreshPendingSince = now }
        // Debounce, but never past `chatRefreshMaxWait` from the first pending update.
        let waited = now.timeIntervalSince(chatRefreshPendingSince ?? now)
        let delay = max(0, min(2.5, Self.chatRefreshMaxWait - waited))
        chatRefreshTask?.cancel()
        chatRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.chatRefreshPendingSince = nil
            await self.refreshChats()
        }
    }

    /// Attach the SwiftData context (call once at launch). Seeds `downloadedIds` from the
    /// persisted "Downloaded" playlist so checkmarks and the Settings count survive relaunches.
    func attachModelContext(_ context: ModelContext) {
        modelContext = context
        let playlists = PlaylistService(context: context)
        if let downloads = playlists.existingDownloads() {
            for ref in downloads.tracks { downloadedIds.insert(ref.remoteUniqueId) }
        }
        if let favorites = playlists.existingFavorites() {
            favoriteIds = Set(favorites.tracks.map(\.remoteUniqueId))
        }
        // After `downloadedIds` is seeded, so explicit downloads are never mistaken for cache.
        restoreAudioCache()
        enforceAudioCacheBudget()
        refreshProfileIds()
        // If auth went `ready` before the context was attached, the launch sync was skipped — run it now.
        if authState == .ready { Task { await syncProfileAudio(); await syncBlockList() } }
    }

    /// Fold a backend download-progress update into the observed UI state, and — on completion —
    /// mark the track downloaded (Downloaded playlist + Settings count).
    private func apply(_ update: TrackDownloadProgress) {
        let key = update.remoteUniqueId
        // The user stopped this one — ignore trailing updates and don't let it re-appear.
        if canceledDownloadIds.contains(key) {
            downloadProgressByTrack[key] = nil
            downloadingIds.remove(key)
            if update.isComplete { canceledDownloadIds.remove(key) }
            return
        }
        if update.isComplete {
            downloadProgressByTrack[key] = nil
            downloadingIds.remove(key)
            // Where the finished file is filed — the one place "Keep everything I play" applies.
            // The user's own download is always a download; a track that merely finished because it
            // was played is a download too *while that setting is on*, and otherwise a **cache**
            // entry: on disk and playable offline, but under the budget and age limit.
            let wasExplicit = explicitDownloadIds.contains(key) || autoDownloadPlayed
            if let track = activeDownloadTracks.removeValue(forKey: key) {
                markDownloaded(track, explicit: wasExplicit, bytes: update.bytes)
            } else if wasExplicit {
                downloadedIds.insert(key)
            } else {
                noteCachedFile(key, bytes: update.bytes)
            }
        } else {
            guard !downloadedIds.contains(key) else { return }
            downloadingIds.insert(key)
            downloadProgressByTrack[key] = update.fraction
        }
    }

    /// The number decides the backend, every time. The App Review demo number never reaches
    /// Telegram — it swaps the app onto the offline mock backend, which then drives the normal
    /// code screen (any code is accepted). **Any other number swaps back to real TDLib**, so a
    /// real login attempted while the mock backend is still in place (after a demo session was
    /// signed out) gets a genuine Telegram code instead of silently logging into the demo.
    /// Every auth step follows the same shape: wait for the link to actually be up, then attempt
    /// with backoff, and only report a failure once we've genuinely run out of attempts. A wrong
    /// code or an invalid number is classified `.backend` by the TDLib mapper, so it is *not*
    /// retried and reaches the user immediately — the retries only ever absorb dropped links.
    @discardableResult
    func setPhoneNumber(_ phone: String) async -> Bool {
        if AppConfig.isDemoPhoneNumber(phone) {
            await enterDemoMode()
        } else {
            await exitDemoMode()
        }
        await awaitAuthPrompt()
        await awaitConnection()
        return await run(policy: .auth, timeout: .seconds(12)) { try await self.backend.setPhoneNumber(phone) }
    }

    @discardableResult
    func checkCode(_ code: String) async -> Bool {
        await awaitConnection()
        return await run(policy: .auth, timeout: .seconds(12)) { try await self.backend.checkCode(code) }
    }

    @discardableResult
    func checkPassword(_ password: String) async -> Bool {
        await awaitConnection()
        return await run(policy: .auth, timeout: .seconds(12)) { try await self.backend.checkPassword(password) }
    }
    /// Nuke the TDLib database and start a fresh client — used to escape a stuck auth
    /// flow (e.g. `waitCode` persisted across app restarts) without a full account wipe.
    func resetAuth() async { await backend.resetAuth() }
    /// A one-shot notice shown on the login screen when the session ended *without* the user
    /// asking to log out (a remote sign-out / revoked session) — so an unexpected logout is
    /// explained rather than silently dumping the user back to the phone screen.
    var sessionExpiredNotice: String?
    /// Set while a *user-initiated* logout is in flight, so a deliberate sign-out can be told
    /// apart from a remote revoke. Cleared once a fresh login reaches `.ready`.
    private(set) var didUserInitiateLogout = false

    /// Whether auth reached `.ready` at some point since the app launched. Falling back to the
    /// phone screen *from* that state is what identifies a remote sign-out — as opposed to a
    /// normal cold start, which begins unauthenticated.
    @ObservationIgnored private var hasBeenReadyThisSession = false

    /// Called when the session ends for **any** reason, so the app can drop playback state that
    /// outlives the account (the queue, the mini-player). Wired to `PlayerEngine.stop()`.
    var onSessionEnded: (() -> Void)?

    func logOut() async {
        didUserInitiateLogout = true
        await wipeLocalAccountData()
        await run { try await self.backend.logOut() }
        // Demo sessions run on the mock backend; hand control back to the real one so the next
        // user gets a genuine Telegram login.
        await exitDemoMode()
    }

    /// The session ended without the user asking — signed out from another device, session
    /// revoked, or the auth key was invalidated. Telegram drops us back at the phone screen, so
    /// we must do everything a deliberate log out does *except* asking the server to log out
    /// (it already has): wipe this account's local data, stop playback, and leave a notice for
    /// the login screen so the user understands why they're suddenly signed out.
    ///
    /// Without this, the next person to sign in on the device inherited the previous account's
    /// playlists, downloads, recently-played and followed artists, and audio kept playing.
    private func handleRemoteSignOut() async {
        guard !didUserInitiateLogout else { return }
        log.error("Session ended remotely — wiping local account data")
        await wipeLocalAccountData()
        // Leave demo mode by clearing the flag rather than swapping the backend here. Building a
        // TDLibTelegramBackend mid-wipe would stand a second client up on the same database
        // directory; the swap happens safely in `setPhoneNumber` when a real number is entered,
        // and the flag is what decides the backend at the next launch.
        isDemoMode = false
        AppConfig.isDemoModeActive = false
        sessionExpiredNotice = "You were signed out of Telegram on another device. Please sign in again."
    }

    /// Erase every trace of the signed-in account from this device. Shared by the deliberate
    /// `logOut()` and the remote-revoke path so the two can never drift.
    private func wipeLocalAccountData() async {
        onSessionEnded?()          // stop playback / dismiss the mini-player
        for task in downloadTasks.values { task.cancel() }
        downloadTasks.removeAll()
        chatRefreshTask?.cancel()
        chatRefreshTask = nil
        offlineDebounce?.cancel()
        offlineDebounce = nil
        account = nil
        searchSources.clear()
        hiddenTracks.clear()
        inlineSearchContext.clear()
        chatMessageCache = [:]
        lastError = nil
        await finalCover.clear(); await provisionalCover.clear()
        await chatPhotoCache.clear(); await artistCover.clear(); await lyricsResolver.clear()

        // Full local wipe: nothing of this account remains on-device after sign-out. (Playlists
        // are cleared too; once they live in our own backend, logout will re-sync them from there
        // instead of dropping them.)
        recentlyPlayed = []; followedArtists = []; pinnedKeys = []; lastOpened = [:]
        countCache = [:]; chats = []; userProfiles = []
        chatAudioCache = [:]; artistAudioCache = [:]; artistRepTrack = [:]
        fastArtistCoverCache = [:]; isArtistCoverHighRes = [:]
        downloadedIds = []; downloadingIds = []; unavailableTrackIds = []; favoriteIds = []
        blockedChatIds = []; blockedTitles = [:]
        knownChatIds = []
        cachedIds = []; audioCache.removeAll(); persistAudioCache(); playbackPlanKeys = []
        profileIds = []
        explicitDownloadIds = []; canceledDownloadIds = []; canceledDownloadOrder = []
        downloadProgressByTrack = [:]; activeDownloadTracks = [:]
        downloads.removeAll()
        downloadRetryTask?.cancel(); downloadRetryTask = nil
        downloadError = nil
        isPreloadingCovers = false; preloadedCoversCount = 0
        isInitialDataReady = false
        communityMembership = .unknown; isJoiningCommunity = false
        playCounts = [:]; playedTracks = [:]
        // Driven off `StorageKeys.perAccount`, not a list written out here. The hand-maintained
        // version is what let the user's search history survive a sign-out and reach the next
        // account: a key added in some other file was simply never added to this one.
        for key in StorageKeys.perAccount {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // ...but `n_isLoggedIn` is answered again immediately, as `false`. Removing it leaves the
        // "was this device signed in?" question *unanswered*, and `hasCachedSession` then falls
        // back to "a TDLib database exists" — which is true on any device that has ever run the
        // app, so the next launch would show the signed-in shell to a signed-out user.
        UserDefaults.standard.set(false, forKey: StorageKeys.isLoggedIn)
        WidgetSharedStore.clear()
        WidgetCenter.shared.reloadAllTimelines()

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AudioCaches")
        try? FileManager.default.removeItem(at: cacheDir)
        if let context = modelContext {
            PlaylistService(context: context).deleteAll()
        }
    }

    /// How long the launch gate may wait for the *essential* data before calling it a failure.
    ///
    /// This used to be 14 seconds around work that included `preloadInitialMusicCovers` — which
    /// carries its own 60-second budget and does iTunes lookups. On any real account the deadline
    /// fired first, so a perfectly healthy launch reported "Connecting to Telegram timed out" and,
    /// worse, the timeout *cancelled the task group*, killing the sync partway through.
    private static let initialSyncTimeout: Duration = .seconds(30)

    /// Auto-retries of a failed launch sync before we stop and let the user decide. A launch that
    /// failed once on a flaky link must not need a manual tap to recover.
    private static let maxInitialSyncRetries = 2

    /// Fast initial sync run on auth ready: system library, profile music, account, the top chats
    /// and their audio counts. Everything else — cover preloading, the full chat probe — is
    /// deliberately **outside** the gate, because none of it decides whether the app is usable.
    func performInitialSync() async {
        guard authState == .ready else { return }
        guard !isInitialSyncInProgress else { return }
        isInitialSyncInProgress = true
        initialSyncError = nil
        defer { isInitialSyncInProgress = false }

        if connectionState == .waitingForNetwork {
            initialSyncError = "No connection to Telegram. Check your internet or VPN connection."
            scheduleInitialSyncRetry()
            return
        }

        do {
            // Race the sync against its deadline. Explicit sendability allows the task-group
            // transfer while MainActor isolation keeps model and UI mutations serialized.
            try await withThrowingTaskGroup(of: Void.self, isolation: #isolation) { group in
                group.addTask { @MainActor @Sendable [weak self] in
                    guard let self else { return }
                    // 1. Ensure system library (Favorites, Downloaded, Your Profile) exists in SwiftData
                    if let context = self.modelContext {
                        PlaylistService(context: context).ensureSystemLibraryInitialized()
                    }

                    async let profileTask: Void = self.syncProfileAudio()
                    async let blockListSync: Void = self.syncBlockList()
                    async let accountTask: Void = self.loadAccount()

                    // 2. Fast initial load of the top 50 chats
                    let loaded = try await self.backend.loadChats(limit: 50)
                    self.chats = self.audioChats(from: loaded, using: self.countCache)
                    self.seedSavedMessagesPin(in: self.chats)
                    self.saveChatsCache()

                    _ = await (profileTask, blockListSync, accountTask)

                    // 3. Probe top audio channels and Saved Messages so initial shelves have counts & dates
                    await self.probeInitialTopChats(loaded)
                }
                group.addTask {
                    try await Task.sleep(for: Self.initialSyncTimeout)
                    throw TelegramError.transient("Couldn't reach Telegram. Check your internet or VPN connection.")
                }
                try await group.next()
                group.cancelAll()
            }

            initialSyncError = nil
            initialSyncRetries = 0
            isInitialDataReady = true

            // Everything below is a *warm-up*, not a gate: the app is already usable, and none of
            // it is allowed to fail the launch or block the first frame.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.preloadInitialMusicCovers()
                await self.probeAudioCounts(self.chats)
                await self.probeUserProfiles(self.chats)
                await self.refreshChats(force: true)
            }
        } catch {
            initialSyncError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            scheduleInitialSyncRetry()
        }
    }

    /// Try again on our own before asking the user to. A launch sync that failed to a dropped
    /// request is the most common case by far, and making someone tap Retry for it is the same
    /// mistake as surfacing a transient error — just with an extra step.
    private func scheduleInitialSyncRetry() {
        guard !isInitialDataReady, initialSyncRetries < Self.maxInitialSyncRetries else { return }
        initialSyncRetries += 1
        let attempt = initialSyncRetries
        initialSyncRetryTask?.cancel()
        initialSyncRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Double(attempt) * 3))
            guard !Task.isCancelled, let self, !self.isInitialDataReady else { return }
            await self.performInitialSync()
        }
    }

    /// User-initiated retry from the "couldn't load" state. Resets the automatic budget, because
    /// a deliberate tap is a fresh start.
    func retryInitialSync() async {
        initialSyncRetries = 0
        initialSyncRetryTask?.cancel()
        initialSyncRetryTask = nil
        await performInitialSync()
    }

    /// Background refresh of the chat list, triggered by TDLib's chat-list update bursts — so it
    /// runs repeatedly for as long as the app is open, including while music plays.
    ///
    /// It used to run *entirely* inside `run`'s 15-second, user-reporting wrapper, which was wrong
    /// twice over. The probe phase walks up to 1000 chats in batches of 16 and legitimately takes
    /// minutes, so on any real account this (a) raised "Connection timed out — check your internet"
    /// over healthy playback, and (b) — worse and silently — the timeout cancelled the task group,
    /// killing the probe partway through, so chats past the first 15 seconds never got their audio
    /// counts. Only the one call that can actually throw gets a deadline now; the probes run
    /// unbounded and handle their own failures, and nothing here reaches the user.
    /// - Parameter force: bypass `chatRefreshTTL`. Used by the launch sync and by an explicit
    ///   pull-to-refresh; the update-driven path stays rate-limited.
    func refreshChats(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastChatRefreshAt) > Self.chatRefreshTTL else { return }
        lastChatRefreshAt = Date()
        isLoadingChats = true
        defer { isLoadingChats = false }
        var loaded: [TelegramChat] = []
        let ok = await run(timeout: .seconds(45), surface: .log) {
            let all = try await self.backend.loadChats(limit: 1000)
            // 1. Show cached audio chats immediately (instant on every launch after the first).
            self.chats = self.audioChats(from: all, using: self.countCache)
            self.knownChatIds.formUnion(all.map(\.id))
            self.seedSavedMessagesPin(in: self.chats)
            self.saveChatsCache()
            loaded = all
        }
        guard ok, !loaded.isEmpty else { return }
        // 2. Re-probe, updating the list progressively as batches finish. No deadline: this is
        // minutes of work by design, and cutting it short just leaves the chat list half-probed.
        await probeAudioCounts(loaded)
        await probeUserProfiles(loaded)
    }

    /// Build the displayed chat list from a count map, preserving load order. **Pure** — it used
    /// to also call `seedDefaultPins`, hiding a write to persisted user state inside something
    /// named and shaped like a transform, and re-running it on every probe batch.
    private func audioChats(from all: [TelegramChat], using counts: [Int64: AudioChatMeta]) -> [TelegramChat] {
        // Blocked sources are dropped here rather than at each call site: this is the single
        // funnel every assignment to `chats` goes through, so the Library, Home shelves and the
        // chat picker all inherit the block without knowing about it.
        all.filter { !blockedChatIds.contains($0.id) }.map { chat in
            var c = chat
            if let meta = counts[chat.id] {
                c.audioCount = meta.count
                c.lastAudioDate = meta.lastDate
            }
            return c
        }
    }

    /// Pin Saved Messages by default once it's known to hold audio. Separated from `audioChats`
    /// so the mutation is an explicit step at the call site rather than a hidden side effect.
    private func seedSavedMessagesPin(in chats: [TelegramChat]) {
        for chat in chats where chat.kind == .savedMessages && (chat.audioCount ?? 0) > 0 {
            seedDefaultPins(["c:\(chat.id)"])
        }
    }

    /// Fast-probe the top 12 prioritized chats (Saved Messages, top music channels) so the initial
    /// UI is populated immediately before the user enters the app.
    private func probeInitialTopChats(_ all: [TelegramChat]) async {
        let prioritized = all.sorted { a, b in
            func priorityScore(_ c: TelegramChat) -> Int {
                switch c.kind {
                case .savedMessages: return 0
                case .channel: return 1
                case .group: return 2
                default: return 3
                }
            }
            return priorityScore(a) < priorityScore(b)
        }
        let topBatch = Array(prioritized.prefix(12))
        guard !topBatch.isEmpty else { return }
        
        await withTaskGroup(of: (Int64, AudioChatMeta).self) { group in
            for chat in topBatch {
                group.addTask { [backend = self.backend] in
                    let (count, date) = await backend.audioCountAndLastDate(in: chat.id)
                    return (chat.id, AudioChatMeta(count: count, lastDate: date, probedAt: Date()))
                }
            }
            for await (id, meta) in group {
                countCache[id] = meta
            }
        }
        chats = audioChats(from: all, using: countCache)
        seedSavedMessagesPin(in: chats)
        saveChatsCache()
        saveCountCache()
    }

    /// Probe each chat's audio count with bounded concurrency, prioritizing music-bearing channels/groups
    /// and Saved Messages so they populate first.
    private func probeAudioCounts(_ all: [TelegramChat]) async {
        let backend = self.backend
        
        // Prioritize Saved Messages, channels, and groups over private DMs
        let prioritized = all.sorted { a, b in
            func priorityScore(_ c: TelegramChat) -> Int {
                switch c.kind {
                case .savedMessages: return 0
                case .channel: return 1
                case .group: return 2
                case .bot: return 3
                case .privateChat: return 4
                case .secret: return 5
                default: return 6
                }
            }
            return priorityScore(a) < priorityScore(b)
        }
        
        // Skip chats probed within the TTL. Without this, every chat-list update re-probed the
        // entire chat list over the network.
        let now = Date()
        let stale = prioritized.filter { chat in
            guard let probedAt = countCache[chat.id]?.probedAt else { return true }
            return now.timeIntervalSince(probedAt) > Self.audioCountTTL
        }
        guard !stale.isEmpty else { return }

        let cap = 16
        var i = 0
        while i < stale.count {
            let slice = Array(stale[i..<min(i + cap, stale.count)])
            await withTaskGroup(of: (Int64, AudioChatMeta).self) { group in
                for chat in slice {
                    group.addTask {
                        let (count, date) = await backend.audioCountAndLastDate(in: chat.id)
                        return (chat.id, AudioChatMeta(count: count, lastDate: date, probedAt: Date()))
                    }
                }
                for await (id, meta) in group {
                    countCache[id] = meta
                }
            }
            chats = audioChats(from: all, using: countCache)
            i += cap
        }
        seedSavedMessagesPin(in: chats)
        // Write the caches once at the end rather than once per 16-chat batch (that was ~63
        // full encode-and-write cycles for a 1000-chat account).
        saveChatsCache()
        saveCountCache()
    }

    /// Probe private chats for user profile music playlists.
    /// Last time each user's profile audio was probed. Without this, every `refreshChats()` — and
    /// that runs on each debounced chat-list update burst — fired one `userProfileAudio` request
    /// per private chat. On an account with a few hundred of them that is a repeating storm of
    /// hundreds of requests. `probeAudioCounts` above was given the same treatment for the same
    /// reason; this one was simply missed.
    @ObservationIgnored private var userProfileProbedAt: [Int64: Date] = [:]
    private static let userProfileTTL: TimeInterval = 10 * 60

    func probeUserProfiles(_ all: [TelegramChat]) async {
        let backend = self.backend
        let now = Date()
        let privateChats = all.filter { chat in
            guard chat.kind == .privateChat else { return false }
            let uid = chat.userId ?? chat.id
            guard let probed = userProfileProbedAt[uid] else { return true }
            return now.timeIntervalSince(probed) > Self.userProfileTTL
        }
        guard !privateChats.isEmpty else { return }
        for chat in privateChats { userProfileProbedAt[chat.userId ?? chat.id] = now }
        
        let cap = 8
        var i = 0
        var discovered: [UserProfilePlaylist] = []
        while i < privateChats.count {
            let slice = Array(privateChats[i..<min(i + cap, privateChats.count)])
            let batchResults = await withTaskGroup(of: UserProfilePlaylist?.self) { group in
                for chat in slice {
                    let uid = chat.userId ?? chat.id
                    group.addTask {
                        guard let tracks = try? await backend.userProfileAudio(userId: uid, limit: 50),
                              !tracks.isEmpty else { return nil }
                        return UserProfilePlaylist(
                            userId: uid,
                            chatId: chat.id,
                            userName: chat.title,
                            photoData: chat.photoData,
                            photoId: chat.photoId,
                            tracks: tracks
                        )
                    }
                }
                var batch: [UserProfilePlaylist] = []
                for await profile in group {
                    if let profile { batch.append(profile) }
                }
                return batch
            }
            discovered.append(contentsOf: batchResults)
            i += cap
        }
        if !discovered.isEmpty {
            var map = Dictionary(uniqueKeysWithValues: userProfiles.map { ($0.userId, $0) })
            for d in discovered {
                map[d.userId] = d
            }
            self.userProfiles = Array(map.values).sorted { $0.userName.localizedCaseInsensitiveCompare($1.userName) == .orderedAscending }
            saveUserProfilesCache()
        }
    }

    /// Preload high-res album art for max 5 tracks in "New in your chats" and profile music
    /// so the Home shelves, Library, and Player display artwork immediately on frame 1.
    func preloadInitialMusicCovers() async {
        guard !isPreloadingCovers else { return }
        isPreloadingCovers = true
        preloadedCoversCount = 0
        defer { isPreloadingCovers = false }

        // Best-effort warm-up: it fetches audio from six chats and resolves covers (iTunes lookups
        // included), which routinely outruns a 15s deadline. Nothing here is worth a banner — the
        // covers simply resolve later, on demand.
        await run(timeout: .seconds(60), surface: .log) {
            // 1. Gather audio messages from top audio-bearing chats to build "New in your chats"
            let audioChats = self.chats.filter { ($0.audioCount ?? 0) > 0 }
            let topChats = Array(audioChats.prefix(6))
            var collectedTracks: [AudioTrack] = []
            
            for chat in topChats {
                var tracks = self.cachedChatAudio(chat.id)
                if tracks.isEmpty {
                    tracks = (try? await self.backend.audioMessages(in: chat.id, limit: 15, fromMessageId: 0)) ?? []
                    if !tracks.isEmpty {
                        self.cacheChatAudio(tracks, chatId: chat.id)
                    }
                }
                collectedTracks.append(contentsOf: tracks)
            }
            
            // 2. Sort newest-first & deduplicate to create "New in your chats" feed
            var seen = Set<String>()
            let newFeed = collectedTracks
                .sorted { ($0.date ?? 0) > ($1.date ?? 0) }
                .filter { seen.insert($0.remoteUniqueId).inserted }
                .prefix(50)
                .map { $0 }
            
            // 3. Persist to "New in your chats" cache so HomeView displays it immediately on launch
            if !newFeed.isEmpty {
                let slim = newFeed.map { $0.withArtwork(nil) }
                if let data = try? JSONEncoder().encode(slim) {
                    UserDefaults.standard.set(data, forKey: StorageKeys.newInChats)
                }
            }
            
            // 4. Preload at most 5 covers from "New in your chats" + profile tracks
            var candidateTracks: [AudioTrack] = []
            if let context = self.modelContext,
               let profilePlaylist = PlaylistService(context: context).existingProfile() {
                candidateTracks.append(contentsOf: profilePlaylist.orderedTracks.map(\.audioTrack).prefix(5))
            }
            candidateTracks.append(contentsOf: newFeed.prefix(5))
            
            var coverSeen = Set<String>()
            let tracksToPreload = Array(candidateTracks.filter { coverSeen.insert($0.remoteUniqueId).inserted }.prefix(5))
            
            await withTaskGroup(of: Void.self) { group in
                for track in tracksToPreload {
                    group.addTask {
                        _ = await self.highResArtwork(for: track)
                    }
                }
            }
            self.preloadedCoversCount = tracksToPreload.count
        }
    }

    // MARK: - Followed artists

    func isFollowing(artist name: String) -> Bool {
        followedArtists.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func toggleFollow(artist name: String) {
        let key = "a:\(name.lowercased())"
        if let idx = followedArtists.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            followedArtists.remove(at: idx)
        } else {
            followedArtists.insert(name, at: 0)
            markOpened(key)
        }
        UserDefaults.standard.set(followedArtists, forKey: artistsKey)
    }

    /// Distinct performers drawn from the user's *own* audio (recently played + any extra
    /// performers passed in, e.g. their playlist tracks) that they don't already follow —
    /// surfaced as "artists you might want to follow" in the Add-artist sheet.
    func suggestedArtists(extraPerformers: [String] = [], limit: Int = 12) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in recentlyPlayed.map(\.performer) + extraPerformers {
            let n = raw.trimmingCharacters(in: .whitespaces)
            guard n.count >= 2, !isFollowing(artist: n), seen.insert(n.lowercased()).inserted else { continue }
            out.append(n)
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: - Library recents

    /// Record that the user opened the library entry with this `pinKey`, so the Recents sort can
    /// float it to the top. Persisted as epoch seconds so it survives relaunches.
    func markOpened(_ key: String) {
        lastOpened[key] = .now
        let serializable = lastOpened.mapValues(\.timeIntervalSince1970)
        UserDefaults.standard.set(serializable, forKey: lastOpenedKey)
    }

    // MARK: - Library pins

    func isPinned(_ key: String) -> Bool { pinnedKeys.contains(key) }

    func setPinned(_ key: String, _ pinned: Bool, atFront: Bool = false) {
        pinnedKeys.removeAll { $0 == key }
        if pinned {
            if atFront {
                pinnedKeys.insert(key, at: 0)
            } else {
                pinnedKeys.append(key)
            }
        }
        UserDefaults.standard.set(pinnedKeys, forKey: pinnedKey)
    }

    /// Pin these keys *by default* (e.g. Favorites / Downloaded) the first time each is seen,
    /// inserting them at the front. Seeding is tracked per-key, so once a default has been
    /// applied the user can freely unpin it without it springing back on the next launch.
    func seedDefaultPins(_ keys: [String]) {
        var seeded = Set(UserDefaults.standard.stringArray(forKey: seededPinsKey) ?? [])
        let fresh = keys.filter { !seeded.contains($0) }
        guard !fresh.isEmpty else { return }
        let toPin = fresh.filter { !pinnedKeys.contains($0) }
        pinnedKeys.insert(contentsOf: toPin, at: 0)
        seeded.formUnion(fresh)
        UserDefaults.standard.set(pinnedKeys, forKey: pinnedKey)
        UserDefaults.standard.set(Array(seeded), forKey: seededPinsKey)
    }

    /// Drag-to-reorder within the pinned set. `visibleKeys` is the on-screen pinned order the
    /// move offsets index into; any keys not currently visible (stale/filtered) keep their
    /// relative position at the end, so the persisted order never loses entries.
    func reorderPinned(visibleKeys: [String], fromOffsets: IndexSet, toOffset: Int) {
        var reordered = visibleKeys
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        let leftover = pinnedKeys.filter { !visibleKeys.contains($0) }
        pinnedKeys = (reordered + leftover).deduped()
        UserDefaults.standard.set(pinnedKeys, forKey: pinnedKey)
    }

    /// Set the pinned order directly to `keys` (any other existing pins keep their tail order).
    func setPinnedOrder(_ keys: [String]) {
        let leftover = pinnedKeys.filter { !keys.contains($0) }
        pinnedKeys = (keys + leftover).deduped()
        UserDefaults.standard.set(pinnedKeys, forKey: pinnedKey)
    }

    /// The one search every surface goes through.
    ///
    /// Telegram's message search is only half the answer: it returns the *same song once per chat
    /// that carries it*, orders by message date rather than relevance, and returns nothing at all
    /// while offline — where the user's own downloads are exactly what they're looking for. So the
    /// server results are merged with a local pass over everything we already know about (cached
    /// chat/artist listings, recently played, every stored playlist track), then de-duplicated on
    /// `remoteUniqueId` and ranked by `AudioSearch`.
    ///
    /// - Parameter includeLocal: `false` to search Telegram only (the artist-page backfill, which
    ///   wants fresh server tracks rather than the cache it is about to replace).
    func searchAudio(_ query: String, includeLocal: Bool = true) async throws -> [AudioTrack] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Local first: it costs no network and gives an instant answer offline.
        let local = includeLocal ? await localMatches(for: trimmed) : []

        var remote: [AudioTrack] = []
        if !isOffline {
            do {
                remote = try await backend.searchAudio(query: trimmed, limit: 100)
            } catch {
                // A dropped request shouldn't blank out results we can serve from disk.
                if local.isEmpty { throw error }
            }
        }
        for track in remote { unavailableTrackIds.remove(track.remoteUniqueId) }

        // Server records lead so de-duplication prefers them (they carry a live source message).
        // `visible` runs last: a blocked chat's tracks come back from the server like any other.
        return visible(AudioSearch.rank(remote + local, query: trimmed))
    }

    /// Everything on this device that could match a search: the per-chat and per-artist listing
    /// caches, recently played, and every track stored in a playlist (which covers Downloaded,
    /// Favorites and Profile Music). Matching runs **off the main actor** — the pool can be tens
    /// of thousands of tracks for a heavy user and folding them all is not work for the actor
    /// driving the keyboard.
    func localMatches(for query: String, limit: Int = 60) async -> [AudioTrack] {
        var pool: [AudioTrack] = recentlyPlayed
        for tracks in chatAudioCache.values { pool += tracks }
        for tracks in artistAudioCache.values { pool += tracks }
        if let context = modelContext {
            pool += PlaylistService(context: context).allStoredTracks()
        }
        // Playlist tracks are in this pool, so a blocked source is filtered out of search even
        // when the user had saved it — the `TrackRef` is kept, only hidden, so unblocking restores
        // it. Deleting their own curation is not what "block this source" asks for.
        let snapshot = visible(pool)
        return await Task.detached(priority: .userInitiated) {
            AudioSearch.rank(snapshot, query: query, limit: limit)
        }.value
    }

    /// Load (or refresh) the logged-in user's profile for the Settings header.
    func loadAccount() async {
        account = await backend.currentAccount()
    }

    func audioMessages(in chatId: Int64, fromMessageId: Int64 = 0) async throws -> [AudioTrack] {
        let tracks = try await backend.audioMessages(in: chatId, limit: 100, fromMessageId: fromMessageId)
        for track in tracks { unavailableTrackIds.remove(track.remoteUniqueId) }
        return tracks
    }

    /// Full-chat playback must not depend on how far the user has scrolled.
    func allChatAudio(
        in chatId: Int64,
        progress: (Int) -> Void = { _ in },
        onPage: ([AudioTrack]) -> Void = { _ in }
    ) async throws -> [AudioTrack] {
        try await ChatAudioCollection.load(
            fetchPage: { try await self.audioMessages(in: chatId, fromMessageId: $0) },
            progress: progress,
            onPage: onPage
        )
    }

    /// Synchronous, instant memory lookup for an artist's cover so views render immediately on frame 1 with 0 flash.
    func quickArtistArtwork(for name: String) -> Data? {
        let key = name.lowercased()
        if let fast = fastArtistCoverCache[key] { return fast }
        if let rep = artistRepTrack[key], let data = rep.artworkData { return data }
        if let first = cachedArtistTracks(name).first(where: { $0.artworkData != nil }) {
            return first.artworkData
        }
        return nil
    }

    /// A cover to represent an artist. Two tiers, prioritizing good quality high-res covers:
    /// 1. A **real iTunes artist portrait/album art** (final, cached).
    /// 2. Otherwise scans the artist's tracks, prioritizing any track with a **high-res final cover** (iTunes/embedded)
    ///    over low-res provisional thumbnails.
    func artistArtwork(for name: String) async -> Data? {
        let key = name.lowercased()

        // 1. iTunes artist photo — tried once per session.
        let offline = isOffline
        if let photo = await artistCover.value(for: key, produce: {
            if offline { throw TelegramError.notReady }
            return try await CoverArtService.artistPhoto(name: name)
        }) {
            fastArtistCoverCache[key] = photo
            isArtistCoverHighRes[key] = true
            return photo
        }

        // 2. If we already have a verified high-res cover from a representative track, return it.
        if let pick = artistRepTrack[key], isArtistCoverHighRes[key] == true {
            let res = await artworkResult(for: pick)
            if res.isHighRes, let data = res.data {
                fastArtistCoverCache[key] = data
                return data
            }
        }

        // 3. Scan candidate tracks for the best quality high-res cover.
        let candidates = await artistTrackCandidates(for: name)
        if let best = await resolveBestArtistCover(for: name, candidates: candidates) {
            return best
        }

        return nil
    }

    /// Re-evaluates the artist cover when opening the artist page or when fresh tracks arrive.
    /// If there is no high-res cover yet, scans the provided or cached tracks and upgrades the cover.
    @discardableResult
    func refreshArtistCover(for name: String, tracks: [AudioTrack]? = nil) async -> Data? {
        let key = name.lowercased()
        let candidates = tracks ?? cachedArtistTracks(name)
        guard !candidates.isEmpty else { return nil }

        // If not already high-res from iTunes, search for a high-res cover among tracks.
        if isArtistCoverHighRes[key] != true {
            if let best = await resolveBestArtistCover(for: name, candidates: candidates) {
                return best
            }
        }
        return fastArtistCoverCache[key]
    }

    private func resolveBestArtistCover(for name: String, candidates: [AudioTrack]) async -> Data? {
        let key = name.lowercased()
        var provisionalBackup: (data: Data, track: AudioTrack)?

        // First pass: look for an already-resolved high-res cover among the tracks
        for track in candidates {
            let res = await artworkResult(for: track)
            if res.isHighRes, let data = res.data {
                artistRepTrack[key] = track
                fastArtistCoverCache[key] = data
                isArtistCoverHighRes[key] = true
                await artistCover.adopt(data, for: key)
                return data
            } else if provisionalBackup == nil, let data = res.data {
                provisionalBackup = (data, track)
            }
        }

        // Second pass: attempt high-res lookup (e.g. iTunes) on top candidates
        for track in candidates.prefix(8) {
            let res = await artworkResult(for: track)
            if res.isHighRes, let data = res.data {
                artistRepTrack[key] = track
                fastArtistCoverCache[key] = data
                isArtistCoverHighRes[key] = true
                await artistCover.adopt(data, for: key)
                return data
            }
        }

        // If no high-res found, use provisional thumbnail without permanently locking as high-res
        if let backup = provisionalBackup {
            artistRepTrack[key] = backup.track
            fastArtistCoverCache[key] = backup.data
            return backup.data
        }

        return nil
    }

    /// The artist's tracks to derive an avatar from. Prefers the **cached** set (the tracks already
    /// known to belong to the artist, collected while browsing — works offline), and only falls back
    /// to a live global search when the cache is empty. Live `searchAudio` is a global message search
    /// that often returns nothing for a performer name, so relying on it alone left artists blank.
    private func artistTrackCandidates(for name: String) async -> [AudioTrack] {
        let cached = cachedArtistTracks(name)
        if !cached.isEmpty { return cached.shuffled() }
        let results = (try? await searchAudio(name, includeLocal: false)) ?? []
        return results.filter { $0.performer.localizedCaseInsensitiveContains(name) }.shuffled()
    }

    func localFile(for track: AudioTrack) async throws -> URL {
        registerActiveDownload(track)
        return try await backend.ensureLocalFile(for: track)
    }

    /// A streaming-capable playback item for the track.
    func playerItem(for track: AudioTrack) async throws -> AVPlayerItem {
        // Already downloaded or cached locally? Play straight from disk with **no** network round-trip — instant,
        // and works offline (the streaming/`getMessage` paths otherwise stall without a network).
        if let url = await backend.localPlayableURL(for: track) {
            markTrackAvailable(track)
            return AVPlayerItem(url: url)
        }
        // Playing a track downloads its file in the background — register it so it lands in the
        // Downloaded library once fully fetched.
        registerActiveDownload(track)
        do {
            let item = try await backend.makePlayerItem(for: track)
            markTrackAvailable(track)
            return item
        } catch {
            if case TelegramError.deleted = error {
                markTrackUnavailable(track)
            }
            throw error
        }
    }

    // MARK: - Favourites

    func isFavorite(_ track: AudioTrack) -> Bool { favoriteIds.contains(track.remoteUniqueId) }

    /// Toggle a track's Favorites membership, keeping the observable mirror in step with SwiftData.
    /// Returns the new state.
    @discardableResult
    func toggleFavorite(_ track: AudioTrack) -> Bool {
        guard let context = modelContext else { return favoriteIds.contains(track.remoteUniqueId) }
        let nowFavorite = PlaylistService(context: context).toggleFavorite(track)
        if nowFavorite {
            favoriteIds.insert(track.remoteUniqueId)
        } else {
            favoriteIds.remove(track.remoteUniqueId)
        }
        return nowFavorite
    }

    // MARK: - Track Availability (Telegram Deletions)

    /// Whether the track was deleted from Telegram and is unresolvable from the server.
    /// Downloaded tracks are never unavailable because their audio bytes live on disk.
    /// Whether this track's audio is on disk **at all** — explicitly downloaded or merely cached
    /// from playing it. This, not `isDownloaded`, is what decides whether something can play with
    /// no network: a cached file is a real file.
    func isAvailableOffline(_ track: AudioTrack) -> Bool {
        isAvailableOffline(remoteUniqueId: track.remoteUniqueId)
    }

    func isAvailableOffline(remoteUniqueId: String) -> Bool {
        downloadedIds.contains(remoteUniqueId) || cachedIds.contains(remoteUniqueId)
    }

    func isUnavailableOnTelegram(_ track: AudioTrack) -> Bool {
        guard !isAvailableOffline(track) else { return false }
        return unavailableTrackIds.contains(track.remoteUniqueId)
    }

    func isUnavailableOnTelegram(remoteUniqueId: String) -> Bool {
        guard !isAvailableOffline(remoteUniqueId: remoteUniqueId) else { return false }
        return unavailableTrackIds.contains(remoteUniqueId)
    }

    /// Mark a track as unavailable when a resolution attempt fails due to deletion.
    func markTrackUnavailable(_ track: AudioTrack) {
        guard !isAvailableOffline(track) else { return }
        unavailableTrackIds.insert(track.remoteUniqueId)
    }

    /// Re-mark a track as available if successfully resolved or re-downloaded.
    func markTrackAvailable(_ track: AudioTrack) {
        unavailableTrackIds.remove(track.remoteUniqueId)
    }

    /// Remember a track so a later completion event can be recorded with full metadata. Skips
    /// tracks already in the offline library.
    private func registerActiveDownload(_ track: AudioTrack) {
        guard !downloadedIds.contains(track.remoteUniqueId) else { return }
        audioCache.touch(track.remoteUniqueId)   // playing it keeps it alive in the LRU
        canceledDownloadIds.remove(track.remoteUniqueId)
        activeDownloadTracks[track.remoteUniqueId] = track
    }

    /// Result of an artwork resolution query, indicating whether the returned data is
    /// a full-resolution final cover (iTunes / embedded file art) or a low-resolution provisional thumbnail.
    struct ArtworkResult: Sendable, Equatable {
        let data: Data?
        let isHighRes: Bool
    }

    /// Resolves the artwork for a track and indicates whether the cover is a high-resolution final
    /// cover or a low-resolution provisional thumbnail.
    func artworkResult(for track: AudioTrack) async -> ArtworkResult {
        let key = track.remoteUniqueId
        let backend = self.backend
        let offline = isOffline   // snapshot: skip network sources while offline

        if let final = await finalCover.cached(for: key) {
            return ArtworkResult(data: final, isHighRes: true)
        } else if let itunes = await finalCover.value(for: key, produce: {
            if offline { throw TelegramError.notReady }
            return try await CoverArtService.artwork(title: track.title, performer: track.performer)
        }) {
            await provisionalCover.invalidate(key)
            return ArtworkResult(data: itunes, isHighRes: true)
        } else if let embedded = await backend.embeddedArtwork(for: track) {
            // Embedded art carries whatever the uploader put in the file — sometimes several
            // thousand pixels. Cap it before it enters the memory/disk tiers.
            let capped = await Task.detached(priority: .utility) {
                ImageDownsampling.capped(embedded, maxPixel: 1000)
            }.value
            await finalCover.adopt(capped, for: key)
            await provisionalCover.invalidate(key)
            return ArtworkResult(data: embedded, isHighRes: true)
        } else if let cachedThumb = await provisionalCover.cached(for: key) {
            return ArtworkResult(data: cachedThumb, isHighRes: false)
        } else if !offline, let thumb = await provisionalCover.value(for: key, produce: {
            await backend.thumbnailArtwork(for: track)
        }) {
            return ArtworkResult(data: thumb, isHighRes: false)
        } else if let inline = track.artworkData {
            return ArtworkResult(data: inline, isHighRes: false)
        }

        return ArtworkResult(data: nil, isHighRes: false)
    }

    /// The single source of truth for a track's cover — used by every surface (`TrackArtwork`,
    /// the player's lock-screen artwork, artist avatars). Resolves the *best* cover and caches
    /// it once (memory + disk), so the same track looks the same everywhere and survives
    /// relaunches.
    ///
    /// Two tiers: a **final** cover, which never changes and always wins, and a **provisional**
    /// cover (Telegram's small thumbnail) shown until a final one is available.
    ///
    /// Within the final tier the order is **iTunes first, embedded art second** — deliberately.
    /// iTunes returns a clean ~1000px official cover, whereas art embedded in a Telegram-sourced
    /// file is often a low-res, cropped or watermarked re-encode. The trade-off is that a track
    /// with perfectly good embedded art still costs one network lookup, and its title + performer
    /// are sent to Apple (see PRIVACY_POLICY). iTunes is tried once per session per track, so the
    /// cost is bounded, and while offline it is skipped entirely and embedded art wins by default.
    ///
    /// A provisional cover never blocks the upgrade — embedded art is re-attempted cheaply
    /// (offline) on each lookup, so a track resolves to a real cover the moment its file is on
    /// disk, regardless of *how* it got downloaded (explicit download or just played).
    func highResArtwork(for track: AudioTrack) async -> Data? {
        let result = await artworkResult(for: track)
        let key = track.remoteUniqueId

        if result.data != nil && recentlyPlayed.prefix(8).contains(where: { $0.remoteUniqueId == key }) {
            syncRecentlyPlayedToWidget()
        }

        return result.data
    }

    /// API lyrics take priority, with cached or embedded file lyrics as an offline fallback.
    /// API misses are tracked separately so file lyrics never block an online upgrade.
    func lyrics(for track: AudioTrack) async -> Lyrics? {
        let backend = self.backend
        return await lyricsResolver.lyrics(for: track.remoteUniqueId, offline: isOffline,
            api: {
                await LyricsService.lyrics(title: track.title, performer: track.performer,
                                          durationSeconds: track.duration)
            }, embedded: {
                await backend.embeddedLyrics(for: track)
            })
    }

    /// Cached full-resolution chat/channel photo (for crisp avatars).
    /// Keyed by `photoId` (the remote uniqueId of the photo file) so a changed
    /// avatar always fetches fresh — different photo → different key → cache miss.
    /// Falls back to keying by chat id when there is no photo (returns nil quickly).
    func chatPhotoData(for chat: TelegramChat) async -> Data? {
        guard let photoId = chat.photoId else { return nil }
        return await chatPhotoCache.value(for: photoId) { [self] in
            await backend.chatPhoto(chatId: chat.id)
        }
    }

    /// Cached full-resolution user profile photo for UserProfilePlaylist.
    func profilePhotoData(for profile: UserProfilePlaylist) async -> Data? {
        if let photoId = profile.photoId {
            return await chatPhotoCache.value(for: photoId) { [self] in
                await backend.chatPhoto(chatId: profile.chatId)
            }
        }
        return await backend.chatPhoto(chatId: profile.chatId)
    }

    /// Refresh profile audios for a specific user profile.
    func refreshUserProfile(for profile: UserProfilePlaylist) async -> [AudioTrack] {
        let tracks = (try? await backend.userProfileAudio(userId: profile.userId, limit: 100)) ?? []
        if !tracks.isEmpty {
            if let idx = userProfiles.firstIndex(where: { $0.userId == profile.userId }) {
                userProfiles[idx].tracks = tracks
            }
            saveUserProfilesCache()
            return tracks
        }
        return profile.tracks
    }

    func canSendMessages(in chatId: Int64) async -> Bool {
        await backend.canSendMessages(in: chatId)
    }


    /// Where a failure from `run` should go.
    ///
    /// `lastError` is read by the playback banner, so it is the **"you asked for this and are
    /// waiting on it"** channel and nothing else. Background housekeeping that reports there tells
    /// the user their connection timed out while their music is playing perfectly well — which is
    /// exactly the bug this enum exists to make hard to write again. (Downloads learned the same
    /// lesson separately; see `downloadError`.)
    enum FailureSurface {
        /// User-initiated and user-visible: sign in, a profile edit, sending a message.
        case user
        /// Background maintenance. Logged, never shown — the user did not ask and is not waiting.
        case log
    }

    /// Run `work` with a per-attempt timeout, retrying transient failures, reporting only the
    /// final failure to `surface`.
    ///
    /// The default `policy` is a single attempt so existing callers behave exactly as before;
    /// the paths where a retry actually helps (login, profile writes) opt in explicitly.
    ///
    /// **Pick `timeout` to fit the work, not by habit.** A deadline shorter than the job is not a
    /// safety net: the timeout cancels the task group, so the work is *killed midway* as well as
    /// reported as a failure.
    /// `work` stays on the main actor; explicit sendability permits safely transferring it to
    /// the task group without removing the isolation its UI and model mutations depend on.
    @discardableResult
    func run(policy: Retry.Policy = .none,
             timeout: Duration = .seconds(15),
             surface: FailureSurface = .user,
             _ work: @escaping @MainActor @Sendable () async throws -> Void) async -> Bool {
        do {
            try await Retry.run(policy) {
                try await withThrowingTaskGroup(of: Void.self, isolation: #isolation) { group in
                    group.addTask { @MainActor @Sendable in try await work() }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw TelegramError.transient("Connection timed out. Please check your internet or VPN connection and try again.")
                    }
                    try await group.next()
                    group.cancelAll()
                }
            }
            return true
        }
        catch is CancellationError {
            // Task cancellation is a normal concurrency event (e.g. child task cancelled when work finishes),
            // do not surface it as an error to the user.
            return false
        }
        catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            switch surface {
            case .user: lastError = reason
            case .log:  log.error("Background task failed: \(reason, privacy: .public)")
            }
            return false
        }
    }

    /// Wait (bounded) for the backend to be in a state where a request can actually succeed.
    ///
    /// Login used to *refuse* to send while `isOffline` — but `isOffline` is true during the
    /// perfectly normal `.connecting` phase of a cold launch, so tapping Continue a second after
    /// opening the app produced "No connection to Telegram" for a connection that was seconds
    /// from being fine. Waiting is the honest answer: hold the spinner, then send.
    func awaitConnection(timeout: Duration = .seconds(8)) async {
        guard isOffline else { return }
        let deadline = Date().addingTimeInterval(timeout.seconds)
        while isOffline, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

}

private extension Array where Element: Hashable {
    /// Order-preserving de-duplication.
    func deduped() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

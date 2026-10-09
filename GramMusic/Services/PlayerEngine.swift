import Foundation
import AVFoundation
import MediaPlayer
import Observation

/// Owns AVFoundation playback, the play queue, and system integration (background audio,
/// lock-screen / Control Center controls, Now Playing info).
///
/// Audio is resolved on demand through `fileProvider` — a closure that downloads (or
/// otherwise produces) a playable file URL for a track. This keeps the engine decoupled
/// from Telegram so it can be tested in isolation.
@MainActor
@Observable
final class PlayerEngine {

    static weak var shared: PlayerEngine?

    typealias FileProvider = @MainActor (AudioTrack) async throws -> URL
    typealias ItemProvider = @MainActor (AudioTrack) async throws -> AVPlayerItem
    typealias ArtworkProvider = @MainActor (AudioTrack) async -> Data?

    enum RepeatMode { case off, all, one }

    /// Backing storage: each slot tagged with where it came from (see `QueueEntry`).
    private(set) var entries: [QueueEntry] = []
    private(set) var unshuffledEntries: [QueueEntry] = []
    private(set) var currentIndex = 0
    /// The tracks in play order — read projection over `entries`. Mutate via the
    /// queue-editing methods (`addToQueue`, `moveInQueue`, …), never directly.
    var queue: [AudioTrack] { entries.map(\.track) }
    /// Where the current queue came from (e.g. a chat or playlist name), for Now Playing.
    private(set) var contextName: String?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// How far into the track playback can already reach without waiting — the end of the loaded
    /// range containing the playhead. Drives the scrubber's "buffered" band, so a track streaming
    /// in from Telegram shows how much of it is actually ready, not just where the playhead is.
    private(set) var bufferedTime: Double = 0
    /// Live audio loudness (0…1) of the playing track, sampled from the audio render thread.
    /// Drives the now-playing equalizer bars so they track the actual sound.
    private(set) var audioLevel: Double = 0
    /// Set while `restoreState()` is repopulating from disk, so assigning `isShuffle` doesn't
    /// re-shuffle a queue that was already persisted in its shuffled order.
    private var isRestoringState = false

    var isShuffle = false {
        didSet {
            if isShuffle != oldValue, !isRestoringState {
                cancelProgressiveShuffle()
                if isShuffle {
                    shuffleRemainingQueue()
                } else {
                    unshuffleRemainingQueue()
                }
                queueDidChange()
            }
            persistState()
        }
    }
    var repeatMode: RepeatMode = .off { didSet { persistState() } }
    var lastError: String?
    /// True when `lastError` is an informational "this format isn't supported yet" notice rather
    /// than a real failure — lets the banner use a calm info style instead of an alarming error one.
    var lastErrorIsInfo = false

    /// Consecutive tracks auto-skipped during advance because they failed to load, so a queue
    /// where nothing loads can't loop forever. Reset on any track that actually loads.
    private var autoSkips = 0

    /// Automatic reloads of the *current* track after a mid-playback failure or stall, reset the
    /// moment audio actually advances again.
    ///
    /// A stream served out of TDLib dies whenever the link does — a tunnel, a VPN reconnect, a
    /// handover. Before this the item simply went `.failed`, we set an error and stopped: the user
    /// had to notice the silence and press play again. Now the engine quietly reloads at the same
    /// position, and only tells them once it has genuinely run out of attempts.
    private var recoveryAttempts = 0
    private static let maxRecoveryAttempts = 3
    /// How long the playhead may sit still, while we believe we're playing, before we treat it as
    /// a wedged stream and reload. Long enough to ride out ordinary rebuffering.
    private static let stallTimeout: TimeInterval = 15
    @ObservationIgnored nonisolated(unsafe) private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var stallWatchdog: Task<Void, Never>?
    /// Playhead and wall clock at the last observed forward progress — the stall watchdog's input.
    private var lastProgressPosition: Double = -1
    private var lastProgressAt: Date = .distantPast
    /// Where the playhead was when the most recent recovery began; the budget is only returned
    /// once playback gets meaningfully past it (see `noteProgress`).
    private var recoveryAnchorPosition: Double = 0

    /// Playback speed (0.75…2.0). Applied live while playing.
    var playbackRate: Float = 1.0 {
        didSet { if isPlaying { player.rate = playbackRate } }
    }

    /// When the sleep timer will pause playback (nil = off).
    private(set) var sleepTimerEnd: Date?
    @ObservationIgnored nonisolated(unsafe) private var sleepTask: Task<Void, Never>?
    private var isSeeking = false

    // MARK: - Equalizer
    private static let eqEnabledKey = "n_eq_enabled"
    private static let eqPresetKey = "n_eq_preset"
    private static let eqGainsKey = "n_eq_gains"

    var isEqualizerEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEqualizerEnabled, forKey: Self.eqEnabledKey)
            syncEqualizer()
        }
    }

    var equalizerPreset: EqualizerPreset = .flat {
        didSet {
            UserDefaults.standard.set(equalizerPreset.rawValue, forKey: Self.eqPresetKey)
            if equalizerPreset != .custom {
                equalizerGains = equalizerPreset.gains
            }
        }
    }

    var equalizerGains: [Float] = [0, 0, 0, 0, 0] {
        didSet {
            if let data = try? JSONEncoder().encode(equalizerGains) {
                UserDefaults.standard.set(data, forKey: Self.eqGainsKey)
            }
            syncEqualizer()
        }
    }

    /// Whether the current load has already been counted as a real "play" (so we record it once,
    /// only after genuine listening — not on load, and not on a rapid skip-through). Reset on
    /// every fresh `loadCurrent`.
    private var hasCountedPlay = false

    var current: AudioTrack? {
        entries.indices.contains(currentIndex) ? entries[currentIndex].track : nil
    }

    /// Upcoming slots that were *manually* added ("Add to Queue") — they always play next, in
    /// order, before the context resumes (and even when shuffle is on). Manual adds are kept
    /// contiguous right after `currentIndex` by `addToQueue`.
    var upcomingUserQueueIndices: [Int] {
        guard currentIndex + 1 < entries.count else { return [] }
        return ((currentIndex + 1)..<entries.count).filter { entries[$0].origin == .userQueue }
    }

    private var currentEntryID: UUID? {
        entries.indices.contains(currentIndex) ? entries[currentIndex].id : nil
    }

    /// Re-point `currentIndex` at the slot with `id` after the array was reordered/trimmed.
    private func restoreCurrentIndex(_ id: UUID?) {
        if let id, let idx = entries.firstIndex(where: { $0.id == id }) { currentIndex = idx }
    }

    /// Start a load, cancelling whatever load was already in flight. Every call site that used to
    /// spawn a bare `Task { await loadCurrent(...) }` goes through here.
    private func beginLoad(_ work: @escaping @MainActor () async -> Void) {
        // Any deliberate load supersedes the position restored from the last session.
        //
        // `pendingResumeTime` was only ever consumed by `resume()` and cleared by `stop()`, so it
        // stayed armed after a cold launch however much you played. Tap a different song (starts at
        // 0:00, correctly), pause it, press play — and `resume()` found the marker still set and
        // reloaded that track at the position of a track from the *previous* session. Clearing it
        // here covers every entry point, since every load goes through this one.
        pendingResumeTime = nil
        loadCurrentTask?.cancel()
        loadCurrentTask = Task { @MainActor in await work() }
    }

    /// Bumped each time a fresh play session starts via `play(tracks:)` (a user tapping a
    /// track / Play / Shuffle). The shell observes this to auto-present Now Playing.
    private(set) var playSessionToken = 0

    private let player = AVPlayer()
    private let fileProvider: FileProvider
    private let itemProvider: ItemProvider?
    private let artworkProvider: ArtworkProvider?
    private var levelTap: AudioLevelTap?

    // Teardown handles. `nonisolated(unsafe)` so the (nonisolated) `deinit` can release them —
    // safe because deinit runs only once the last reference is gone, so nothing else can race it.
    // `@ObservationIgnored` is required, not cosmetic: without it the @Observable macro turns these
    // into computed properties, and `nonisolated(unsafe)` on a computed property does nothing.
    @ObservationIgnored nonisolated(unsafe) private var timeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var levelPump: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var stallObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) private var bufferEmptyObserver: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) private var likelyToKeepUpObserver: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false
    @ObservationIgnored nonisolated(unsafe) private var loadingTask: Task<Void, Never>?
    /// The in-flight `loadCurrent`. Starting a new load **cancels** it.
    ///
    /// Token checks alone were not enough. A load that is merely superseded keeps running to
    /// completion, and `replaceItem` performs a real side effect — `player.replaceCurrentItem` —
    /// *after* an `await`. So a slow load (an undownloaded track with streaming off) could install
    /// its item into the player long after the user had moved to a different song, and its
    /// `isPlaybackLikelyToKeepUp` observer would then find `isPlaying == true` and start it:
    /// audio from track A while the UI showed track B.
    @ObservationIgnored nonisolated(unsafe) private var loadCurrentTask: Task<Void, Never>?
    private var loadToken = UUID()
    @ObservationIgnored nonisolated(unsafe) private var progressiveShuffleTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var progressiveShuffleID: UUID?

    // MARK: Restore
    private static let persistKey = "n_playerState"
    /// After a cold-launch restore, the queue/position are in memory but no `AVPlayerItem`
    /// is loaded yet — the first `resume()` lazily loads the current track and seeks here.
    private var pendingResumeTime: Double?
    /// Throttle position writes (the time observer fires ~2×/sec).
    private var lastPositionSave: Date = .distantPast
    /// Trailing debounce for the (whole-queue) state write. See `persistState`.
    @ObservationIgnored nonisolated(unsafe) private var persistTask: Task<Void, Never>?

    private struct PersistedState: Codable {
        var entries: [QueueEntry]
        /// The pre-shuffle order. Optional so state written before this field existed still
        /// decodes; when absent we fall back to `entries`.
        var unshuffledEntries: [QueueEntry]?
        var currentIndex: Int
        var contextName: String?
        var currentTime: Double
        var isShuffle: Bool
        var repeatRaw: Int
    }

    /// Pre-QueueEntry layout (a flat `[AudioTrack]`). Decoded as a fallback so an existing
    /// saved queue isn't lost on upgrade — every track is treated as `.context`.
    private struct LegacyPersistedState: Codable {
        var queue: [AudioTrack]
        var currentIndex: Int
        var contextName: String?
        var currentTime: Double
        var isShuffle: Bool
        var repeatRaw: Int
    }

    /// `itemProvider` builds a (possibly streaming) `AVPlayerItem` for playback; `fileProvider`
    /// is still used to warm the cache of adjacent tracks. If no item provider is given, items
    /// are built from `fileProvider`'s fully-downloaded URL.
    /// Called once a track has been **genuinely listened to** (see `recordPlayIfListened`), so
    /// skipping through a queue neither pollutes "recently played" nor inflates play counts.
    var onTrackStarted: ((AudioTrack) -> Void)?
    var onSearchTrackListened: ((AudioTrack) -> Void)?

    /// What playback wants downloaded, in strict order: the playing track, then the one after it
    /// (see `defaultLookahead` — deliberately just those two). Fired on every track load and every
    /// queue edit, before any listen threshold, so downloads re-aim immediately rather than
    /// waiting for the track to "count" as played.
    ///
    /// The engine deliberately does **not** download anything itself. It used to warm its
    /// neighbours by calling `fileProvider` directly, which bypassed the download queue, its
    /// concurrency cap and its two lanes — so the cap was never real and the canceller could not
    /// stop a transfer it had never started. Declaring the plan and letting `TelegramService`
    /// schedule it leaves exactly one path to the network.
    var onDownloadPlanChanged: (([AudioTrack]) -> Void)?

    /// `true` when a track can't be played *right now* — i.e. we're offline and it isn't downloaded.
    /// The queue keeps such tracks (so they return once online), but playback hops over them.
    var isUnavailableOffline: ((AudioTrack) -> Bool)?
    var unavailableQueueNotice: (([AudioTrack]) -> String)?

    /// Asked for more music when the queue runs out, so playback continues instead of stopping.
    /// Gets the track that just finished (as a seed for "more like this") and the ids already in
    /// the queue; must return only tracks that can play **now** — which offline means downloaded.
    /// Kept as a closure for the same reason as the providers above: the engine knows nothing
    /// about Telegram, downloads, or what "related" means. Wired in `GramMusicApp`.
    typealias AutoplayProvider = @MainActor (_ seed: AudioTrack?, _ exclude: Set<String>) async -> [AudioTrack]
    var autoplayProvider: AutoplayProvider?

    /// Keep playing past the end of the queue (Settings ▸ Playback). On by default.
    var isAutoplayEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isAutoplayEnabled, forKey: Self.autoplayKey) }
    }
    private static let autoplayKey = "n_autoplay"

    /// Guards against re-entering the extension while its fetch is in flight, and against growing
    /// the queue without bound when a provider keeps handing back tracks.
    private var isExtendingQueue = false
    private var autoplayExtensions = 0
    private static let maxAutoplayExtensions = 3

    init(fileProvider: @escaping FileProvider,
         itemProvider: ItemProvider? = nil,
         artworkProvider: ArtworkProvider? = nil) {
        self.fileProvider = fileProvider
        self.itemProvider = itemProvider
        self.artworkProvider = artworkProvider
        configureAudioSession()
        configureRemoteCommands()
        observeTime()

        // Restore Equalizer settings
        let eqEnabled = UserDefaults.standard.bool(forKey: Self.eqEnabledKey)
        let presetRaw = UserDefaults.standard.string(forKey: Self.eqPresetKey) ?? EqualizerPreset.flat.rawValue
        let preset = EqualizerPreset(rawValue: presetRaw) ?? .flat
        var gains = preset.gains
        if let gainsData = UserDefaults.standard.data(forKey: Self.eqGainsKey),
           let savedGains = try? JSONDecoder().decode([Float].self, from: gainsData),
           savedGains.count == 5 {
            gains = savedGains
        }
        self.isEqualizerEnabled = eqEnabled
        self.equalizerPreset = preset
        self.equalizerGains = gains
        self.isAutoplayEnabled = UserDefaults.standard.object(forKey: Self.autoplayKey) as? Bool ?? true
        Self.shared = self
    }

    /// Release the system hooks this engine installed. The engine is app-lifetime today, so this
    /// mostly matters for tests — each `PlayerEngine` built in a test case otherwise leaves a live
    /// periodic time observer and two `AVAudioSession` notification registrations behind.
    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        statusObserver?.invalidate()
        bufferEmptyObserver?.invalidate()
        likelyToKeepUpObserver?.invalidate()
        levelPump?.cancel()
        sleepTask?.cancel()
        loadingTask?.cancel()
        recoveryTask?.cancel()
        stallWatchdog?.cancel()
        persistTask?.cancel()
        loadCurrentTask?.cancel()
        progressiveShuffleTask?.cancel()
    }

    // MARK: - Equalizer Control

    func setEqualizerEnabled(_ enabled: Bool) {
        isEqualizerEnabled = enabled
    }

    func setEqualizerPreset(_ preset: EqualizerPreset) {
        equalizerPreset = preset
        if preset != .custom {
            equalizerGains = preset.gains
        }
    }

    func setEqualizerGain(_ gain: Float, at bandIndex: Int) {
        guard equalizerGains.indices.contains(bandIndex) else { return }
        var updated = equalizerGains
        updated[bandIndex] = min(12.0, max(-12.0, gain))
        equalizerPreset = .custom
        equalizerGains = updated
    }

    func resetEqualizer() {
        equalizerPreset = .flat
        equalizerGains = EqualizerPreset.flat.gains
    }

    private func syncEqualizer() {
        levelTap?.updateEqualizer(enabled: isEqualizerEnabled, gains: equalizerGains)
    }

    // MARK: - Queue editing

    /// Insert a track at the *front* of the manual-queue zone (Apple-Music "Play Next"). Not
    /// surfaced in the UI today (we only ship "Add to Queue"), but kept for parity.
    func playNext(_ track: AudioTrack, fromSearch: Bool = false) {
        guard !entries.isEmpty else { play(tracks: [track], fromSearch: fromSearch); return }
        let entry = QueueEntry(track, origin: .userQueue, fromSearch: fromSearch)
        let insertPos = min(currentIndex + 1, entries.count)
        entries.insert(entry, at: insertPos)
        if let currentId = currentEntryID,
           let unIdx = unshuffledEntries.firstIndex(where: { $0.id == currentId }) {
            unshuffledEntries.insert(entry, at: min(unIdx + 1, unshuffledEntries.count))
        } else {
            unshuffledEntries.append(entry)
        }
        queueDidChange()
        persistState()
    }

    /// Spotify "Add to Queue": append to the *bottom of the manual-queue zone* — after the
    /// current track and any already-queued manual adds, but before the rest of the context
    /// resumes. So queued songs play next-then-next, then playback returns to the playlist.
    func addToQueue(_ track: AudioTrack, fromSearch: Bool = false) {
        guard !entries.isEmpty else { play(tracks: [track], fromSearch: fromSearch); return }
        let entry = QueueEntry(track, origin: .userQueue, fromSearch: fromSearch)
        var insertAt = currentIndex + 1
        while insertAt < entries.count, entries[insertAt].origin == .userQueue { insertAt += 1 }
        entries.insert(entry, at: insertAt)

        if let currentId = currentEntryID,
           let unIdx = unshuffledEntries.firstIndex(where: { $0.id == currentId }) {
            var unInsertAt = unIdx + 1
            while unInsertAt < unshuffledEntries.count, unshuffledEntries[unInsertAt].origin == .userQueue { unInsertAt += 1 }
            unshuffledEntries.insert(entry, at: unInsertAt)
        } else {
            unshuffledEntries.append(entry)
        }
        queueDidChange()
        persistState()
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        let id = currentEntryID
        entries.move(fromOffsets: source, toOffset: destination)
        restoreCurrentIndex(id)
        queueDidChange()
        persistState()
    }

    func removeFromQueue(at offsets: IndexSet) {
        // Don't remove the currently-playing track.
        let removable = offsets.filter { $0 != currentIndex }
        guard !removable.isEmpty else { return }
        let id = currentEntryID
        let removedIds = Set(removable.map { entries[$0].id })
        entries.remove(atOffsets: IndexSet(removable))
        unshuffledEntries.removeAll { removedIds.contains($0.id) }
        restoreCurrentIndex(id)
        queueDidChange()
        persistState()
    }

    /// Drop every track from a blocked source out of the queue — including, if necessary, the one
    /// that is playing.
    ///
    /// `removeFromQueue(at:)` deliberately refuses to remove the current track, which is right for
    /// a user editing their queue and wrong here: blocking the song you are listening to and
    /// having it keep playing is the one outcome that makes the feature look broken. So a blocked
    /// current track skips to the next surviving entry, or stops playback when nothing survives.
    func removeBlockedSources(_ chatIds: Set<Int64>) {
        guard !chatIds.isEmpty else { return }
        removeExcludedTracks { chatIds.contains($0.chatId) }
    }

    func removeHiddenTracks(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        removeExcludedTracks { ids.contains($0.remoteUniqueId) }
    }

    private func removeExcludedTracks(where shouldRemove: (AudioTrack) -> Bool) {
        guard !entries.isEmpty else { return }
        let currentIsBlocked = current.map(shouldRemove) ?? false
        let survivors = entries.filter { !shouldRemove($0.track) }
        guard survivors.count != entries.count else { return }

        guard !survivors.isEmpty else { stop(); return }

        let currentID = currentEntryID
        entries = survivors
        unshuffledEntries.removeAll { shouldRemove($0.track) }

        if currentIsBlocked {
            // The old current entry is gone, so `restoreCurrentIndex` has nothing to anchor to.
            // Land on whatever now occupies its slot, clamped, and load it.
            currentIndex = min(currentIndex, entries.count - 1)
            resetPlayhead()
            queueDidChange()
            persistState()
            let wasPlaying = isPlaying
            beginLoad { [weak self] in await self?.loadCurrent(autoPlay: wasPlaying) }
        } else {
            restoreCurrentIndex(currentID)
            queueDidChange()
            persistState()
        }
    }

    /// Stop playback entirely and clear the queue (dismisses the mini-player).
    func stop() {
        cancelProgressiveShuffle()
        loadToken = UUID()
        loadCurrentTask?.cancel()
        loadCurrentTask = nil
        player.pause()
        stopLevelPump()
        stopStallWatchdog()
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryAttempts = 0
        levelTap = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        endObserver = nil
        stallObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
        bufferEmptyObserver?.invalidate()
        bufferEmptyObserver = nil
        likelyToKeepUpObserver?.invalidate()
        likelyToKeepUpObserver = nil
        player.replaceCurrentItem(with: nil)
        entries = []
        unshuffledEntries = []
        currentIndex = 0
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        bufferedTime = 0
        pendingResumeTime = nil
        // The old context label would otherwise survive into the next session's Now Playing header.
        contextName = nil
        onDownloadPlanChanged?([])   // nothing is playing: stop chasing downloads for it
        autoSkips = 0
        autoplayExtensions = 0
        isExtendingQueue = false
        nowPlayingArtwork = nil
        updateNowPlaying()
        flushState()   // empty queue → clears the saved state
    }

    // MARK: - Queue control

    /// Replace the queue and start playing at `startIndex` (or randomize the entire queue if `randomizeFirst` is true).
    func play(tracks: [AudioTrack], startAt startIndex: Int = 0, context: String? = nil, randomizeFirst: Bool = false, fromSearch: Bool = false) {
        guard !tracks.isEmpty else { return }
        cancelProgressiveShuffle()
        // Starting a fresh context replaces the whole queue, including any pending manual
        // adds (matches Spotify — a new play clears the queue).
        let initialEntries = tracks.map { QueueEntry($0, origin: .context, fromSearch: fromSearch) }
        entries = initialEntries
        unshuffledEntries = initialEntries
        contextName = context
        
        if isShuffle, entries.count > 1 {
            if randomizeFirst {
                entries.shuffle()
                currentIndex = 0
            } else {
                let clamped = min(max(startIndex, 0), tracks.count - 1)
                let currentTrack = entries[clamped]
                var otherTracks = entries
                otherTracks.remove(at: clamped)
                otherTracks.shuffle()
                entries = [currentTrack] + otherTracks
                currentIndex = 0
            }
        } else {
            currentIndex = min(max(startIndex, 0), tracks.count - 1)
        }
        
        playSessionToken &+= 1
        autoSkips = 0
        autoplayExtensions = 0   // a deliberate new play gets a fresh autoplay budget
        resetPlayhead()
        beginLoad { [weak self] in await self?.loadCurrent(autoPlay: true) }
    }

    /// Zero the displayed position for a track that is about to start from the beginning.
    ///
    /// The queue changes synchronously but the load is async, so without this the scrubber keeps
    /// showing the *previous* track's position — or, straight after a cold launch, the position
    /// restored from the last session — until the load lands a moment later.
    private func resetPlayhead() {
        currentTime = 0
        bufferedTime = 0
    }

    /// Convenience for dedicated "Shuffle" buttons: randomizes the entire queue completely so any track can start first.
    func shufflePlay(tracks: [AudioTrack], context: String? = nil) {
        isShuffle = true
        play(tracks: tracks, startAt: 0, context: context, randomizeFirst: true)
    }

    /// Start with the tracks already in memory, then let the caller expand the remaining queue
    /// page by page. Replacing the queue or changing shuffle state cancels the expansion.
    @discardableResult
    func shufflePlayProgressively(
        tracks: [AudioTrack],
        context: String? = nil,
        expand: @escaping @MainActor (UUID) async -> Void
    ) -> UUID? {
        guard !tracks.isEmpty else { return nil }
        isShuffle = true
        play(tracks: tracks, startAt: 0, context: context, randomizeFirst: true)
        let id = UUID()
        progressiveShuffleID = id
        progressiveShuffleTask = Task { @MainActor [weak self] in
            await expand(id)
            guard self?.progressiveShuffleID == id else { return }
            self?.progressiveShuffleID = nil
            self?.progressiveShuffleTask = nil
        }
        return id
    }

    /// Add a newly fetched page to the active progressive shuffle. The played/current prefix and
    /// manual queue zone keep their positions; new tracks are inserted randomly among the
    /// remaining context entries.
    @discardableResult
    func appendToProgressiveShuffle(_ tracks: [AudioTrack], sessionID: UUID) -> Int {
        guard progressiveShuffleID == sessionID, isShuffle, !tracks.isEmpty else { return 0 }
        var known = Set(entries.map { $0.track.id })
        let fresh = tracks.filter { known.insert($0.id).inserted }
        guard !fresh.isEmpty else { return 0 }
        let added = fresh.map { QueueEntry($0, origin: .context) }
        unshuffledEntries.append(contentsOf: added)
        var contextStart = min(currentIndex + 1, entries.count)
        while contextStart < entries.count, entries[contextStart].origin == .userQueue {
            contextStart += 1
        }
        let remaining = Array(entries.dropFirst(contextStart))
        let incoming = added.shuffled()
        var merged: [QueueEntry] = []
        merged.reserveCapacity(remaining.count + incoming.count)
        var oldIndex = 0
        var newIndex = 0
        // Weighted interleaving gives each fresh song a random slot without repeated
        // array insertion or reshuffling the songs already waiting to play.
        while oldIndex < remaining.count || newIndex < incoming.count {
            let oldCount = remaining.count - oldIndex
            let newCount = incoming.count - newIndex
            if Int.random(in: 0..<(oldCount + newCount)) < newCount {
                merged.append(incoming[newIndex])
                newIndex += 1
            } else {
                merged.append(remaining[oldIndex])
                oldIndex += 1
            }
        }
        entries.replaceSubrange(contextStart..., with: merged)
        queueDidChange()
        persistState()
        return added.count
    }

    private func cancelProgressiveShuffle() {
        progressiveShuffleID = nil
        progressiveShuffleTask?.cancel()
        progressiveShuffleTask = nil
    }

    /// Jump to a specific queue index (used by the Now Playing queue list).
    func jump(to index: Int) {
        guard entries.indices.contains(index) else { return }
        currentIndex = index
        resetPlayhead()
        beginLoad { [weak self] in await self?.loadCurrent(autoPlay: true) }
    }

    func playSingle(_ track: AudioTrack) { play(tracks: [track]) }

    func append(_ track: AudioTrack) {
        let entry = QueueEntry(track, origin: .context)
        entries.append(entry)
        unshuffledEntries.append(entry)
        if entries.count == 1 { beginLoad { [weak self] in await self?.loadCurrent(autoPlay: true) } }
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        guard current != nil else { return }
        // First play after a cold-launch restore: no item is loaded yet, so load the
        // current track and seek to where we left off (clear the marker first to avoid
        // re-entering when `loadCurrent` calls back into `resume`).
        if let resumeTime = pendingResumeTime {
            pendingResumeTime = nil
            beginLoad { [weak self] in await self?.loadCurrent(autoPlay: true, seekTo: resumeTime) }
            return
        }
        // First play activates the session; later plays re-activate, which guards against a
        // session deactivated by an interruption leaving playback silent after a track switch.
        activateAudioSession()
        player.play()
        if playbackRate != 1.0 { player.rate = playbackRate }
        isPlaying = true
        startLevelPump()
        startStallWatchdog()
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        stopLevelPump()
        stopStallWatchdog()
        recoveryTask?.cancel()
        updateNowPlaying()
        flushState()   // a pause is very often the last thing before the app goes away
    }

    // MARK: - Equalizer level pump

    /// While playing, copy the tap's realtime loudness onto the observable `audioLevel` at
    /// ~30fps so SwiftUI can animate the equalizer. Stopped (and zeroed) when not playing.
    private func startLevelPump() {
        guard levelPump == nil else { return }
        levelPump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Assigning an @Observable property notifies even when the value is unchanged,
                // which invalidated every Equalizer and the Aurora backdrop 30×/sec. Only publish
                // a level the UI can actually distinguish.
                let level = Double(self.levelTap?.currentLevel ?? 0)
                if abs(level - self.audioLevel) >= 0.01 { self.audioLevel = level }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopLevelPump() {
        levelPump?.cancel()
        levelPump = nil
        audioLevel = 0
    }

    // MARK: - Mid-playback recovery

    /// Watches wall-clock time against the playhead while we believe we're playing.
    ///
    /// It has to be a wall-clock task, not the periodic time observer: `addPeriodicTimeObserver`
    /// fires off the *playback* clock, so it goes quiet exactly when playback wedges — the one
    /// moment we need to hear from it.
    private func startStallWatchdog() {
        guard stallWatchdog == nil else { return }
        lastProgressPosition = currentTime
        lastProgressAt = Date()
        stallWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.isPlaying else { return }
                if self.currentTime > self.lastProgressPosition + 0.25 {
                    self.noteProgress()
                } else if Date().timeIntervalSince(self.lastProgressAt) > Self.stallTimeout {
                    self.recoverCurrentItem(reason: "playback stalled")
                    return
                }
            }
        }
    }

    private func stopStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = nil
    }

    /// Audio actually advanced — the stream is healthy, so hand back a full recovery budget.
    ///
    /// The budget is only returned after a few seconds of *sustained* playback past where the last
    /// recovery started. Clearing it on the first tick after a reload would hand a broken stream an
    /// unlimited supply of attempts: fail, reload, play 0.5s, fail, reload, forever.
    private func noteProgress() {
        lastProgressPosition = currentTime
        lastProgressAt = Date()
        if recoveryAttempts != 0, currentTime >= recoveryAnchorPosition + 5 {
            recoveryAttempts = 0
        }
    }

    /// Reload the current track at the position it died at, instead of stopping.
    ///
    /// Used for both failure modes of a network-backed item: `AVPlayerItem.status == .failed`
    /// (the stream broke) and a wedged playhead (the stream is open but starved). Gives up after
    /// `maxRecoveryAttempts` and only *then* surfaces `message` — so a two-second tunnel is
    /// invisible to the user, while a genuinely broken track still says so.
    private func recoverCurrentItem(reason: String, message: String? = nil) {
        guard current != nil else { return }
        guard recoveryAttempts < Self.maxRecoveryAttempts else {
            log.error("Playback recovery exhausted (\(reason, privacy: .public))")
            stopStallWatchdog()
            player.pause()
            isPlaying = false
            isLoading = false
            lastError = message ?? "Playback stopped — the connection to Telegram was lost."
            lastErrorIsInfo = false
            return
        }
        recoveryAttempts += 1
        let attempt = recoveryAttempts
        log.info("Recovering playback (\(reason, privacy: .public)), attempt \(attempt)")
        let resumeAt = currentTime
        let wasPlaying = isPlaying
        recoveryAnchorPosition = resumeAt
        stopStallWatchdog()
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            // +1 because `delay(forAttempt:)` treats the first attempt as immediate.
            try? await Task.sleep(for: Retry.delay(forAttempt: attempt + 1, policy: .playback))
            guard !Task.isCancelled, let self else { return }
            await self.loadCurrent(autoPlay: wasPlaying, seekTo: resumeAt, isRecovery: true)
        }
    }

    /// Whether the slot at `index` can actually play *right now* — i.e. it's downloaded, or we're
    /// online and can stream it.
    private func isPlayableNow(_ index: Int) -> Bool {
        guard entries.indices.contains(index) else { return false }
        guard let unavailable = isUnavailableOffline else { return true }
        return !unavailable(entries[index].track)
    }

    /// The slot a skip should land on, walking in `direction` past anything that can't play now.
    ///
    /// **Never returns `currentIndex`** — that is the whole point. Skipping used to just increment
    /// the index and let `loadCurrent` "fix up" an unplayable landing by searching forward and then
    /// *backward*; offline, the backward search found the track we had just skipped away from, so
    /// Next reloaded the song already playing and the queue was stuck on it forever.
    ///
    /// Manual "Add to Queue" entries still play first and in order, and repeat-all still wraps —
    /// but both now respect what is actually playable.
    private func skipTarget(forward: Bool) -> Int? {
        let count = entries.count
        guard count > 0 else { return nil }
        if forward, let manual = upcomingUserQueueIndices.first(where: { isPlayableNow($0) }) {
            return manual
        }
        let step = forward ? 1 : -1
        var index = currentIndex
        // At most `count - 1` hops, so a queue where nothing else can play terminates instead of
        // circling back to where it started.
        for _ in 0..<max(count - 1, 1) {
            index += step
            if index >= count {
                guard repeatMode == .all else { return nil }
                index = 0
            } else if index < 0 {
                guard repeatMode == .all else { return nil }
                index = count - 1
            }
            if index == currentIndex { return nil }
            if isPlayableNow(index) { return index }
        }
        return nil
    }

    /// Preview the same availability-aware target used by the transport controls.
    /// Autoplay's next track is unknown until it has been fetched.
    func skipPreview(forward: Bool) -> AudioTrack? {
        if !forward, currentTime > 3 { return current }
        guard let target = skipTarget(forward: forward) else {
            return forward ? nil : current
        }
        return entries[target].track
    }

    func next() {
        guard !entries.isEmpty else { return }
        guard let target = skipTarget(forward: true) else {
            // Nothing further in this queue can play. Try to keep the music going instead of
            // silently doing nothing (see `handleQueueEnd`).
            handleQueueEnd(.userSkip)
            return
        }
        let origin = currentIndex
        currentIndex = target
        resetPlayhead()
        // Auto-skip forward over anything that fails to load, so one bad track doesn't stall the
        // queue; the `autoSkips` guard stops a queue where nothing loads from looping.
        beginLoad { [weak self] in
            await self?.loadCurrent(autoPlay: true, origin: origin,
                                    onUnsupported: { [weak self] in self?.next() })
        }
    }

    /// Start (or clear with `nil`) a sleep timer that pauses playback after `minutes`.
    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes else { sleepTimerEnd = nil; sleepTask = nil; return }
        let seconds = Double(minutes) * 60
        sleepTimerEnd = Date().addingTimeInterval(seconds)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.pause()
            self.sleepTimerEnd = nil
            self.sleepTask = nil
        }
    }

    func cycleRepeatMode() {
        repeatMode = switch repeatMode { case .off: .all; case .all: .one; case .one: .off }
    }

    /// Whether a "next" action will actually do something.
    ///
    /// Now derived from the same `skipTarget` that `next()` uses, so the button can't be lit while
    /// pressing it does nothing — which is exactly what happened offline (and, before that, for a
    /// shuffled queue sitting on its last slot with repeat off).
    var hasNext: Bool {
        if skipTarget(forward: true) != nil { return true }
        // Autoplay may still fetch something to skip into. Note this deliberately does *not* count
        // "we could loop the queue" — offering Next when the only outcome is replaying this very
        // track is how the button came to look alive while doing nothing.
        return isAutoplayEnabled && autoplayProvider != nil
            && autoplayExtensions < Self.maxAutoplayExtensions
    }

    func previous() {
        // Restart the current track if we're more than 3s in, else step back to the previous one
        // that can actually play.
        guard currentTime <= 3, let target = skipTarget(forward: false) else {
            seek(to: 0)
            return
        }
        let origin = currentIndex
        currentIndex = target
        resetPlayhead()
        beginLoad { [weak self] in
            await self?.loadCurrent(autoPlay: true, skipForward: false, origin: origin,
                                    onUnsupported: { [weak self] in self?.previous() })
        }
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        isSeeking = true
        player.seek(to: time) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
            }
        }
        currentTime = seconds
        updateNowPlayingPosition()
        // Position-only change — throttled like the periodic save. Scrubbing used to JSON-encode
        // the entire queue (twice) on every drag update and every remote scrub command.
        persistState(throttlePosition: true)
    }

    // MARK: - Loading

    /// - Parameter onUnsupported: called when the track fails to load, to hop to the adjacent
    ///   track in the same direction instead of stalling — whatever the reason. `nil` for explicit
    ///   user picks (play/jump), which surface the notice instead of silently moving on.
    /// Nearest queue index from `start` (inclusive) in the given direction whose track *can* play
    /// now (downloaded, or we're online), or `nil` if there is none. Used to hop over un-streamable
    /// tracks while offline without dropping them from the queue.
    /// - Parameter excluding: an index this search must not return — the slot a skip came *from*.
    ///   Without it the opposite-direction fallback below happily re-selects the track the user
    ///   just skipped away from, which is how playback got pinned to one song offline.
    private func nearestAvailable(from start: Int, forward: Bool, excluding: Int? = nil) -> Int? {
        guard let unavailable = isUnavailableOffline, entries.indices.contains(start) else { return nil }
        let indices = forward ? Array(start..<entries.count) : Array((0...start).reversed())
        return indices.first { $0 != excluding && !unavailable(entries[$0].track) }
    }

    /// - Parameter isRecovery: set when this load is an automatic re-attempt after a mid-playback
    ///   failure, so it doesn't clear the recovery budget it is spending.
    /// - Parameter origin: the slot a skip started from, so the availability fallback can't bounce
    ///   straight back onto it. `nil` for a fresh load (play/jump/restore), where searching both
    ///   directions for something playable is the right thing to do.
    private func loadCurrent(autoPlay: Bool, seekTo: Double = 0, skipForward: Bool = true,
                             isRecovery: Bool = false, origin: Int? = nil,
                             onUnsupported: (() -> Void)? = nil) async {
        guard let pending = current else { return }
        // Offline & not downloaded: this one can't stream. Hop to the nearest downloaded track in the
        // play direction (then the other way). The queue is left intact, so skipped tracks return
        // automatically once back online. If nothing in the queue is downloaded, stop with a notice.
        if isUnavailableOffline?(pending) == true {
            if let idx = nearestAvailable(from: currentIndex, forward: skipForward, excluding: origin)
                        ?? nearestAvailable(from: currentIndex, forward: !skipForward, excluding: origin) {
                currentIndex = idx
            } else {
                player.pause(); player.replaceCurrentItem(with: nil)
                isPlaying = false; isLoading = false
                lastError = unavailableQueueNotice?(entries.map(\.track))
                    ?? "Not downloaded — connect to the internet to play these."
                lastErrorIsInfo = true
                updateNowPlaying()
                return
            }
        }
        guard let track = current else { return }
        let token = UUID()
        loadToken = token
        recoveryTask?.cancel()
        stopStallWatchdog()
        if !isRecovery { recoveryAttempts = 0 }   // a fresh, deliberate load gets a full budget
        hasCountedPlay = false   // arm the "actually listened" detector for this fresh load
        lastError = nil
        lastErrorIsInfo = false
        // Stop whatever is currently playing right away, so the previous track doesn't
        // keep sounding while the new one downloads.
        player.pause()
        player.replaceCurrentItem(with: nil)
        
        loadingTask?.cancel()
        loadingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, self.loadToken == token else { return }
            self.isLoading = true
        }

        defer {
            loadingTask?.cancel()
            if loadToken == token { isLoading = false }
        }

        do {
            // Resolving the item is a network call, so a flaky link fails it for reasons that have
            // nothing to do with the track. Retry those quietly; a genuine problem with the file
            // (unsupported container, deleted message) is classified non-retryable and falls
            // straight through to the handling below.
            let item = try await Retry.run(
                .playback,
                isRetryable: { [weak self] error in
                    TelegramError.isRetryable(error) && self?.loadToken == token
                }
            ) {
                if let itemProvider {
                    return try await itemProvider(track)   // streaming-capable
                }
                return AVPlayerItem(url: try await fileProvider(track))
            }
            guard loadToken == token, !Task.isCancelled else { return }   // a newer load superseded this one
            autoSkips = 0                        // reached a track that actually loads

            // Kick off the fire-and-forget work *before* awaiting the tap install, so cover
            // resolution and download prioritisation aren't held up by `loadTracks`.
            publishDownloadPlan()   // prioritise downloads now, not after the listen threshold
            fetchArtworkIfNeeded(for: track)
            preloadUpcomingArtwork()

            await replaceItem(item, token: token)
            guard loadToken == token, !Task.isCancelled else { return }   // installing suspended; re-check
            duration = Double(track.duration)
            // Actually move the playhead. Assigning `currentTime` alone only updated the label,
            // so a restored position was displayed but audio still began at 0:00.
            if seekTo > 0 {
                await player.seek(to: CMTime(seconds: seekTo, preferredTimescale: 600))
                guard loadToken == token else { return }
            }
            currentTime = seekTo
            bufferedTime = 0
            if autoPlay {
                resume()
                // NOTE: deliberately *not* calling `onTrackStarted` here. It fires from
                // `recordPlayIfListened()` once the track has actually been listened to, so
                // skipping through a queue doesn't pollute history or inflate play counts.
            } else {
                updateNowPlaying()
            }
            persistState()
        } catch is CancellationError {
            // Task cancelled when user skipped to another track
            return
        } catch {
            guard loadToken == token else { return }
            // **Auto-advance never stops on an error.** Whatever went wrong — an undecodable
            // container, a deleted message, or a load that failed even after `Retry` spent its
            // attempts — it is *this one track's* problem, so hop to the next one and keep the
            // music going. The `autoSkips` guard (capped at the queue length) stops a queue where
            // nothing loads from looping forever.
            //
            // This used to hop only for `unsupportedFormat`/`deleted`; any other failure went
            // silent mid-queue, which from the user's side is the app simply stopping.
            if let onUnsupported, autoSkips < entries.count - 1 {
                autoSkips += 1
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                // We recovered by moving on, so this is a notice, not a failure.
                lastErrorIsInfo = true
                onUnsupported()
                return
            }
            // An explicit pick (play/jump), or a queue we've already walked: now it is real news.
            let isTrackSpecific: Bool
            if case TelegramError.unsupportedFormat = error {
                isTrackSpecific = true
            } else if case TelegramError.deleted = error {
                isTrackSpecific = true
            } else {
                isTrackSpecific = false
            }
            autoSkips = 0
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastErrorIsInfo = isTrackSpecific
            isPlaying = false
        }
    }

    /// Fetch a higher-res album cover once per track and patch it into the queue so the
    /// Now Playing screen and lock screen show real artwork.
    private func fetchArtworkIfNeeded(for track: AudioTrack) {
        guard let artworkProvider else { return }
        // Defer to the single cover resolver (`TelegramService.highResArtwork`) — it owns the
        // memory + disk cache, so this is cheap when already resolved and self-heals to the
        // full-res cover once the track's file is on disk. Run on every track load so the
        // lock-screen / Dynamic Island art reflects the best cover available.
        Task { [weak self] in
            guard let data = await artworkProvider(track), let self else { return }
            self.applyArtwork(data, id: track.remoteUniqueId)
        }
    }

    private func applyArtwork(_ data: Data, id: String) {
        // Overwrite unconditionally: a queue track often already carries the low-res inline
        // minithumbnail, and skipping those (the old `artworkData == nil` guard) left the
        // lock screen / Dynamic Island stuck on the small placeholder instead of this
        // higher-res cover.
        var updatedCurrent = false
        for idx in entries.indices where entries[idx].track.remoteUniqueId == id {
            entries[idx].track = entries[idx].track.withArtwork(data)
            if idx == currentIndex {
                updatedCurrent = true
            }
        }
        for idx in unshuffledEntries.indices where unshuffledEntries[idx].track.remoteUniqueId == id {
            unshuffledEntries[idx].track = unshuffledEntries[idx].track.withArtwork(data)
        }
        if updatedCurrent {
            updateNowPlaying()
        }
    }

    /// The next `limit` slots in **play order** — manual "Add to Queue" entries first (they always
    /// play next, in order), then the rest of the context, then the wrap-around if repeat-all will
    /// take us back to the top.
    ///
    /// Shared by the artwork preloader and the download plan so the two can never disagree about
    /// what is coming next. It stops as soon as it has enough; the version this replaced walked the
    /// *entire* remaining queue with an O(n) `contains` per step — O(n²) for a 3-item result — on
    /// every queue edit, shuffle toggle and track load.
    private func upcomingIndices(limit: Int) -> [Int] {
        guard limit > 0, !entries.isEmpty else { return [] }
        var result: [Int] = []
        var seen = Set<Int>()
        func take(_ idx: Int) -> Bool {
            if seen.insert(idx).inserted { result.append(idx) }
            return result.count >= limit
        }
        var sequence = upcomingUserQueueIndices.makeIterator()
        var done = false
        while !done, let idx = sequence.next() { done = take(idx) }
        if !done, currentIndex + 1 < entries.count {
            for idx in (currentIndex + 1)..<entries.count where !done { done = take(idx) }
        }
        if !done, repeatMode == .all, currentIndex > 0 {
            for idx in 0..<currentIndex where !done { done = take(idx) }
        }
        return result
    }

    /// How far past the playing track to fetch, by default.
    ///
    /// **One.** The playing track plus the one after it — enough that pressing Next starts
    /// instantly, and no more. A deeper lookahead reads well on paper and is hostile in practice:
    /// it spends the user's mobile data on tracks they will most likely skip past, and every extra
    /// transfer is bandwidth taken from the song actually playing. (It was 4 briefly, which meant
    /// five simultaneous downloads the moment you pressed play.)
    ///
    /// The `.upcoming` tier still exists for callers that ask for a deeper plan; nothing at the
    /// default depth uses it.
    // `nonisolated`: used as a default argument, which is evaluated outside the actor.
    nonisolated static let defaultLookahead = 1

    /// What downloads should target, most urgent first: the track playing right now, then the one
    /// that plays after it, then any further lookahead. Exactly the order the scheduler consumes.
    func downloadPlan(lookahead: Int = PlayerEngine.defaultLookahead) -> [AudioTrack] {
        guard let playing = current else { return [] }
        return [playing] + upcomingIndices(limit: lookahead).compactMap { idx in
            entries.indices.contains(idx) ? entries[idx].track : nil
        }
    }

    /// Hand the current plan to whoever schedules downloads. Cheap and idempotent, so it is safe
    /// to call from every queue mutation.
    private func publishDownloadPlan() {
        guard let onDownloadPlanChanged else { return }
        onDownloadPlanChanged(downloadPlan())
    }

    /// The queue changed shape — re-aim both the artwork preloader and the download plan.
    private func queueDidChange() {
        preloadUpcomingArtwork()
        publishDownloadPlan()
    }

    /// Preload cover artwork for upcoming tracks in the queue so next tracks render their art instantly.
    private func preloadUpcomingArtwork(limit: Int = 3) {
        guard let artworkProvider, !entries.isEmpty else { return }

        let tracksToPreload = upcomingIndices(limit: limit).compactMap { idx -> AudioTrack? in
            entries.indices.contains(idx) ? entries[idx].track : nil
        }
        guard !tracksToPreload.isEmpty else { return }
        
        Task { [weak self, artworkProvider] in
            for track in tracksToPreload {
                guard let data = await artworkProvider(track) else { continue }
                guard let self else { return }
                self.applyArtwork(data, id: track.remoteUniqueId)
            }
        }
    }

    /// `async` so the level/EQ tap is spliced into the item's audio mix **before** it becomes the
    /// current item. Installing after `replaceCurrentItem` raced playback: setting `audioMix` on an
    /// already-playing item could be ignored, silently dropping the EQ for that track.
    /// - Parameter token: the load this item belongs to. Installing is the one genuinely
    ///   irreversible step, and it happens *after* an `await`, so the token is re-checked
    ///   immediately before it. Without that, a slow load could hand the player its item long
    ///   after the user had moved on — and the observers below would then resume it.
    private func replaceItem(_ item: AVPlayerItem, token: UUID) async {
        item.audioTimePitchAlgorithm = .timeDomain   // pitch-corrected speed
        // Splice in a fresh level meter & equalizer processor for the new item, before it goes live.
        // Nothing above touches the player, so bailing out after this leaves no trace.
        let tap = AudioLevelTap()
        await tap.install(on: item, eqEnabled: isEqualizerEnabled, gains: equalizerGains)
        guard loadToken == token, !Task.isCancelled else { return }

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        statusObserver?.invalidate()
        bufferEmptyObserver?.invalidate()
        likelyToKeepUpObserver?.invalidate()
        levelTap = tap
        player.replaceCurrentItem(with: item)
        // Surface AVPlayer-side failures — TDLib can hand us a perfectly good local file that
        // still fails to decode/play. Without this the failure is silent (no sound, no error).
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item, self.loadToken == token else { return }
                if item.status == .failed {
                    let reason = Self.describe(error: item.error, item: item)
                    let format = Self.sniffFormat(item: item)
                    log.error("AVPlayerItem failed: \(reason, privacy: .public) | file=\(format, privacy: .public)")
                    // Don't stop. A stream served from TDLib fails whenever the link does, and the
                    // fix is the same reload the user would do by hand — so do it for them, and
                    // only surface the error once the retries are spent.
                    self.recoverCurrentItem(
                        reason: "item failed",
                        message: item.error?.localizedDescription ?? "Playback failed."
                    )
                }
            }
        }
        bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item, self.loadToken == token else { return }
                if item.isPlaybackBufferEmpty && self.isPlaying {
                    self.loadingTask?.cancel()
                    self.loadingTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        guard !Task.isCancelled, self.player.currentItem === item, item.isPlaybackBufferEmpty else { return }
                        self.isLoading = true
                    }
                }
            }
        }
        likelyToKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item, self.loadToken == token else { return }
                if item.isPlaybackLikelyToKeepUp {
                    self.loadingTask?.cancel()
                    self.isLoading = false
                    if self.isPlaying && self.player.rate == 0 {
                        self.player.play()
                        if self.playbackRate != 1.0 { self.player.rate = self.playbackRate }
                    }
                }
            }
        }
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying, self.player.currentItem === item else { return }
                self.isLoading = true
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.handleTrackEnded()
            }
        }
    }

    /// Unpack the full NSError chain plus the player item's error log — the top-level
    /// `localizedDescription` is almost always the useless "operation could not be completed";
    /// the real cause (domain/code, underlying OSStatus, server status) lives below it.
    private static func describe(error: Error?, item: AVPlayerItem) -> String {
        var parts: [String] = []
        if let ns = error as NSError? {
            parts.append("\(ns.domain) code=\(ns.code): \(ns.localizedDescription)")
            if let failure = ns.localizedFailureReason { parts.append("reason=\(failure)") }
            var underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            while let u = underlying {
                parts.append("↳ \(u.domain) code=\(u.code): \(u.localizedDescription)")
                underlying = u.userInfo[NSUnderlyingErrorKey] as? NSError
            }
        } else {
            parts.append("no NSError")
        }
        if let last = item.errorLog()?.events.last {
            parts.append("errorLog: status=\(last.errorStatusCode) domain=\(last.errorDomain) \(last.errorComment ?? "")")
        }
        return parts.joined(separator: " | ")
    }

    /// Identify the real container of the on-disk file by its magic bytes — a failed `.mp3`
    /// is very often actually Opus/OGG/FLAC/etc. (Telegram plays those with its own decoders;
    /// AVFoundation can't). Returns a short tag for the log, or a note if not a local file.
    /// Shares the `AudioFormat` sniffer with the backend so the two never drift.
    private static func sniffFormat(item: AVPlayerItem) -> String {
        guard let url = (item.asset as? AVURLAsset)?.url else { return "no asset url" }
        guard url.isFileURL else { return "non-file url scheme=\(url.scheme ?? "?")" }
        return "ext=.\(url.pathExtension.lowercased()) → \(AudioFormat.describe(path: url.path))"
    }

    private func handleTrackEnded() {
        if repeatMode == .one {
            seek(to: 0)
            resume()
        } else if skipTarget(forward: true) != nil {
            next()
        } else {
            handleQueueEnd(.trackEnded)
        }
    }

    // MARK: - Running out of queue

    /// Why we reached the end of the queue. It changes the right answer: a track that *finished*
    /// should loop rather than leave silence, but a user who *pressed Next* and gets the same song
    /// reloaded is looking at the very bug this whole path exists to fix.
    private enum QueueEndReason { case trackEnded, userSkip }

    /// The end of the queue, handled instead of falling silent.
    ///
    /// With Autoplay on we, in order:
    ///   1. ask `autoplayProvider` for more tracks that can play *now* (offline that means
    ///      downloaded ones) and continue into them;
    ///   2. on a finished track, **start the queue again** from its first playable track;
    ///   3. on a user skip with nothing to skip to, stay put — reloading the current track is
    ///      precisely the one-song loop we are fixing;
    ///   4. and if nothing at all can play, stop.
    /// With Autoplay off, repeat-all remains the explicit way to loop.
    private func handleQueueEnd(_ reason: QueueEndReason) {
        guard isAutoplayEnabled else {
            if reason == .trackEnded { stopAtEndOfQueue() }
            return
        }
        if !isExtendingQueue, autoplayExtensions < Self.maxAutoplayExtensions,
           let provider = autoplayProvider {
            extendQueue(using: provider, reason: reason)
            return
        }
        finishQueueEnd(reason)
    }

    /// Fetch more music and continue into it. Falls back to `finishQueueEnd` when the provider has
    /// nothing to offer, or offers only tracks that still can't play.
    private func extendQueue(using provider: @escaping AutoplayProvider, reason: QueueEndReason) {
        isExtendingQueue = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isExtendingQueue = false }
            let exclude = Set(self.entries.map(\.track.remoteUniqueId))
            let more = await provider(self.current, exclude)
            guard !more.isEmpty else { self.finishQueueEnd(reason); return }
            self.autoplayExtensions += 1
            let added = more.map { QueueEntry($0, origin: .context) }
            self.entries.append(contentsOf: added)
            self.unshuffledEntries.append(contentsOf: added)
            self.queueDidChange()
            self.persistState()
            // Only follow the extension if something in it can actually play; a provider that hands
            // back tracks we must skip over would otherwise just grow the queue and still be stuck.
            guard let target = self.skipTarget(forward: true) else {
                self.finishQueueEnd(reason)
                return
            }
            self.currentIndex = target
            await self.loadCurrent(autoPlay: true)
        }
    }

    private func finishQueueEnd(_ reason: QueueEndReason) {
        switch reason {
        case .trackEnded: restartQueue()
        case .userSkip:   break   // nothing to skip to — stay on this track rather than reload it
        }
    }

    /// Play the queue again from its first track that can play now.
    private func restartQueue() {
        guard let first = entries.indices.first(where: { isPlayableNow($0) }) else {
            // Nothing in the queue is playable — worth explaining, because from the outside this
            // looks like the app simply stopped. (Reaching the end of a playlist normally does not
            // get a banner; that is not a problem, it is just the end.)
            stopAtEndOfQueue()
            lastError = unavailableQueueNotice?(entries.map(\.track))
                    ?? "Not downloaded — connect to the internet to play these."
            lastErrorIsInfo = true
            return
        }
        currentIndex = first
        beginLoad { [weak self] in await self?.loadCurrent(autoPlay: true) }
    }

    private func stopAtEndOfQueue() {
        isPlaying = false
        seek(to: 0)
    }

    // MARK: - Time observation

    private func observeTime() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isSeeking else { return }
                self.currentTime = time.seconds
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                self.updateNowPlayingPosition()
                self.updateBufferedTime()
                self.recordPlayIfListened()
                if self.isPlaying {
                    self.noteProgress()   // audio is moving → the stall watchdog stays quiet
                    self.persistState(throttlePosition: true)
                }
            }
        }
    }

    /// Recompute how much of the track is ready to play.
    ///
    /// `loadedTimeRanges` can hold several disjoint ranges (after a seek, say); the only one that
    /// matters is the one the playhead is inside, because that is how far playback can run
    /// uninterrupted. Published only on a change the eye could see — this runs twice a second and
    /// assigning an `@Observable` property invalidates the view whether or not the value differs.
    private func updateBufferedTime() {
        guard let item = player.currentItem else {
            if bufferedTime != 0 { bufferedTime = 0 }
            return
        }
        var reach: Double = 0
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = start + range.duration.seconds
            guard start.isFinite, end.isFinite else { continue }
            // Tolerate a small gap so a range starting a hair after the playhead still counts.
            guard start <= currentTime + 0.5 else { continue }
            reach = max(reach, end)
        }
        if abs(reach - bufferedTime) > 0.25 { bufferedTime = reach }
    }

    /// Record the current track as "recently played" / bump its play count — but only after it has
    /// genuinely been listened to, so skipping past a track never pollutes history. The bar is a
    /// few seconds of *actual* playback (proportionally less for very short clips). Fires once per
    /// load via `hasCountedPlay`.
    private func recordPlayIfListened() {
        guard isPlaying, !hasCountedPlay, let track = current else { return }
        let threshold = min(8, max(2, duration * 0.5))   // short tracks count sooner
        guard currentTime >= threshold else { return }
        hasCountedPlay = true
        onTrackStarted?(track)
        if entries.indices.contains(currentIndex), entries[currentIndex].fromSearch {
            onSearchTrackListened?(track)
        }
    }

    // MARK: - System integration

    /// Set to `true` once we have actually activated the audio session (first playback).
    private var didActivateAudioSession = false

    /// Activate the shared audio session, lazily. Deliberately **not** done at init: the engine is
    /// constructed in `GramMusicApp.init`, so activating there would interrupt whatever the user
    /// was already listening to (Spotify, a podcast) merely by opening GramMusic — even if they
    /// never press play. Idempotent; `resume()` calls it on every play to recover from a session
    /// deactivated by an interruption.
    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            didActivateAudioSession = true
        } catch {
            lastError = "Audio session error: \(error.localizedDescription)"
            lastErrorIsInfo = false
        }
    }

    private func configureAudioSession() {
        // Category only — declaring intent doesn't interrupt anyone. Activation is deferred.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            lastError = "Audio session error: \(error.localizedDescription)"
            lastErrorIsInfo = false
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // Unpack here, in the notification's own (nonisolated) context, and hand the handler
            // only `UInt`s. `Notification` is not Sendable, so passing it across into main-actor
            // isolation is a data race under the Swift 6 language mode — and nothing in it is
            // needed beyond these two values anyway. `queue: .main` makes the isolation assumption
            // safe.
            let info = notification.userInfo
            let type = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = info?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleAudioInterruption(type: type, options: options) }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.handleAudioRouteChange(reason: reason) }
        }
    }

    private func handleAudioInterruption(type typeValue: UInt?, options optionsValue: UInt?) {
        guard let typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                pause()
            }
        case .ended:
            guard wasPlayingBeforeInterruption else { return }
            wasPlayingBeforeInterruption = false
            if let optionsValue {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    resume()
                }
            }
        @unknown default:
            break
        }
    }

    private func handleAudioRouteChange(reason reasonValue: UInt?) {
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        // When old audio output device becomes unavailable (e.g. headphones or AirPods disconnected)
        if reason == .oldDeviceUnavailable {
            if isPlaying {
                pause()
            }
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: e.positionTime)
            return .success
        }
    }

    /// The decoded lock-screen cover, kept so the 2×/sec tick doesn't re-decode it. Keyed by
    /// track id *and* artwork bytes, because `applyArtwork` upgrades the cover in place when the
    /// hi-res one resolves — the id alone would pin the first (thumbnail) decode forever.
    private var nowPlayingArtwork: (key: String, bytes: Int, artwork: MPMediaItemArtwork)?

    private func cachedArtwork(for track: AudioTrack) -> MPMediaItemArtwork? {
        guard let data = track.artworkData else { return nil }
        let key = track.remoteUniqueId
        if let cached = nowPlayingArtwork, cached.key == key, cached.bytes == data.count {
            return cached.artwork
        }
        guard let image = UIImage(data: data) else { return nil }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        nowPlayingArtwork = (key, data.count, artwork)
        return artwork
    }

    /// Full metadata push — title/artist/artwork. Only call when the *track* changes (or its
    /// artwork arrives); it decodes the cover and hands a whole fresh dictionary to the media
    /// server over XPC.
    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            nowPlayingArtwork = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyArtist: track.displaySubtitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            // Must reflect the *actual* rate, else the lock-screen / Control Center scrubber
            // drifts out of sync whenever playback speed isn't 1×.
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(playbackRate),
        ]
        if let artwork = cachedArtwork(for: track) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Position-only refresh for the 2×/sec time observer. Mutates the three values that actually
    /// change while a track plays and leaves the rest of the dictionary (crucially the decoded
    /// artwork) untouched — `updateNowPlaying` used to re-decode the full-res cover on every tick.
    private func updateNowPlayingPosition() {
        guard current != nil, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            updateNowPlaying()
            return
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(playbackRate) : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Persistence (resume where you left off)

    /// Restore the last queue + position from disk so the mini-player reappears on launch
    /// paused at where playback stopped. Audio isn't loaded until the first `resume()`
    /// (the backend may not be ready yet, and many tracks resolve offline). Call once at
    /// startup; a no-op if a queue is already loaded or nothing was saved.
    func restoreState() {
        guard entries.isEmpty,
              let data = UserDefaults.standard.data(forKey: Self.persistKey) else { return }
        let decoder = JSONDecoder()

        let saved: (entries: [QueueEntry], unshuffled: [QueueEntry], index: Int, context: String?,
                    time: Double, shuffle: Bool, repeatRaw: Int)?
        if let s = try? decoder.decode(PersistedState.self, from: data), !s.entries.isEmpty {
            saved = (s.entries, s.unshuffledEntries ?? s.entries, s.currentIndex,
                     s.contextName, s.currentTime, s.isShuffle, s.repeatRaw)
        } else if let s = try? decoder.decode(LegacyPersistedState.self, from: data), !s.queue.isEmpty {
            let entries = s.queue.map { QueueEntry($0, origin: .context) }
            saved = (entries, entries, s.currentIndex,
                     s.contextName, s.currentTime, s.isShuffle, s.repeatRaw)
        } else {
            saved = nil
        }
        guard let saved, !saved.entries.isEmpty else { return }

        // TDLib file ids are session-scoped — a stored positive id is stale now and would
        // skip the offline `getRemoteFile` re-resolution, so reset it to -1 (same as the
        // recently-played restore in TelegramService).
        func rehydrate(_ list: [QueueEntry]) -> [QueueEntry] {
            list.map { QueueEntry($0.track.rehydratedForOfflineResolution(), origin: $0.origin, id: $0.id) }
        }
        isRestoringState = true
        defer { isRestoringState = false }

        entries = rehydrate(saved.entries)
        // The pre-shuffle order is restored separately: `entries` was persisted in *shuffled*
        // order, so mirroring it here (as this used to) permanently lost the original order —
        // turning shuffle off after a relaunch restored nothing.
        unshuffledEntries = rehydrate(saved.unshuffled)
        currentIndex = min(max(saved.index, 0), entries.count - 1)
        contextName = saved.context
        // "Resume where you left off" — the saved position was decoded and then thrown away
        // (both of these were hardcoded to 0), so every relaunch restarted the track from 0:00.
        let resumeAt = max(0, saved.time)
        currentTime = resumeAt
        duration = Double(current?.duration ?? 0)
        isShuffle = saved.shuffle       // guarded by isRestoringState: restores the flag, doesn't re-shuffle
        repeatMode = RepeatMode(raw: saved.repeatRaw)
        pendingResumeTime = resumeAt
        updateNowPlaying()
    }

    private func persistState(throttlePosition: Bool = false) {
        if throttlePosition {
            guard Date().timeIntervalSince(lastPositionSave) > 5 else { return }
            lastPositionSave = Date()
        }
        guard !entries.isEmpty else {
            persistTask?.cancel()
            persistTask = nil
            UserDefaults.standard.removeObject(forKey: Self.persistKey)
            return
        }
        // Coalesce onto a trailing write. Every shuffle toggle, queue edit and track load
        // re-encoded the *entire* queue to UserDefaults synchronously on the main actor; on a long
        // queue that is a visible hitch, and nothing reads this back before the next launch.
        // `flushState()` covers backgrounding and teardown.
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flushState()
        }
    }

    /// Write the queue + position now. Called on a trailing debounce, and directly when the app
    /// backgrounds or playback stops.
    func flushState() {
        persistTask?.cancel()
        persistTask = nil
        guard !entries.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.persistKey)
            return
        }
        // Drop artwork blobs before persisting (covers re-resolve on load).
        func slim(_ list: [QueueEntry]) -> [QueueEntry] {
            list.map { QueueEntry($0.track.withArtwork(nil), origin: $0.origin, id: $0.id) }
        }
        let state = PersistedState(entries: slim(entries),
                                   unshuffledEntries: slim(unshuffledEntries),
                                   currentIndex: currentIndex, contextName: contextName,
                                   currentTime: currentTime, isShuffle: isShuffle,
                                   repeatRaw: repeatMode.raw)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
    }

    // MARK: - Shuffle Logic

    private func shuffleRemainingQueue() {
        guard currentIndex + 1 < entries.count else { return }
        let remainingRange = (currentIndex + 1)..<entries.count
        var contextTracks = [QueueEntry]()
        var newRemaining = [QueueEntry]()
        for i in remainingRange {
            if entries[i].origin == .context { contextTracks.append(entries[i]) }
        }
        contextTracks.shuffle()
        var shuffleIndex = 0
        for i in remainingRange {
            if entries[i].origin == .context {
                newRemaining.append(contextTracks[shuffleIndex])
                shuffleIndex += 1
            } else {
                newRemaining.append(entries[i])
            }
        }
        let id = currentEntryID
        entries.replaceSubrange(remainingRange, with: newRemaining)
        restoreCurrentIndex(id)
    }

    private func unshuffleRemainingQueue() {
        guard currentIndex + 1 < entries.count else { return }
        let remainingRange = (currentIndex + 1)..<entries.count
        var contextTracks = [QueueEntry]()
        var newRemaining = [QueueEntry]()
        for i in remainingRange {
            if entries[i].origin == .context { contextTracks.append(entries[i]) }
        }

        // Positions in the pre-shuffle order, resolved once. The comparator used to run two
        // `firstIndex(where:)` scans per comparison, making un-shuffling O(n² log n) — a visible
        // main-actor stall on a long queue.
        var originalIndex = [UUID: Int](minimumCapacity: unshuffledEntries.count)
        for (i, entry) in unshuffledEntries.enumerated() { originalIndex[entry.id] = i }

        let currentEntry = entries.indices.contains(currentIndex) ? entries[currentIndex] : nil
        let currentUnshuffledIndex = currentEntry.flatMap { originalIndex[$0.id] } ?? -1

        // Precompute each entry's sort key so the comparator is a plain integer compare.
        func sortKey(_ entry: QueueEntry) -> Int {
            let idx = originalIndex[entry.id] ?? Int.max
            return (idx > currentUnshuffledIndex) ? (idx - currentUnshuffledIndex) : (idx + 1_000_000)
        }
        var keyed = contextTracks.map { (key: sortKey($0), entry: $0) }
        keyed.sort { $0.key < $1.key }
        contextTracks = keyed.map(\.entry)
        var restoreIndex = 0
        for i in remainingRange {
            if entries[i].origin == .context {
                newRemaining.append(contextTracks[restoreIndex])
                restoreIndex += 1
            } else {
                newRemaining.append(entries[i])
            }
        }
        let id = currentEntryID
        entries.replaceSubrange(remainingRange, with: newRemaining)
        restoreCurrentIndex(id)
    }
}

private extension PlayerEngine.RepeatMode {
    var raw: Int { switch self { case .off: 0; case .all: 1; case .one: 2 } }
    init(raw: Int) { self = switch raw { case 1: .all; case 2: .one; default: .off } }
}

/// One slot in the play queue, tagged with where it came from. `.context` is the playing
/// playlist/album/chat; `.userQueue` is a manual "Add to Queue". The tag drives the Now-Playing
/// queue's "Next in Queue" vs "Next from <context>" split, and lets shuffle/auto-advance keep
/// manual adds playing first and in order. The per-slot `id` gives each row a stable identity
/// (so duplicate tracks don't collide) and survives reorder/persist.
struct QueueEntry: Identifiable, Hashable, Codable {
    enum Origin: String, Codable { case context, userQueue }
    let id: UUID
    var track: AudioTrack
    var origin: Origin
    var fromSearch: Bool

    init(_ track: AudioTrack, origin: Origin, id: UUID = UUID(), fromSearch: Bool = false) {
        self.id = id
        self.track = track
        self.origin = origin
        self.fromSearch = fromSearch
    }

    private enum CodingKeys: String, CodingKey { case id, track, origin, fromSearch }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        track = try values.decode(AudioTrack.self, forKey: .track)
        origin = try values.decode(Origin.self, forKey: .origin)
        fromSearch = try values.decodeIfPresent(Bool.self, forKey: .fromSearch) ?? false
    }
}

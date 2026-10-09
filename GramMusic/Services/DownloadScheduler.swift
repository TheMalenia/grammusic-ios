import Foundation

/// Why a track is being downloaded, which *is* its position in the queue.
///
/// The order is the product rule: **the song playing right now comes first, the one that plays
/// after it comes second, then the rest of what's coming up, and only then bulk work the user
/// asked for in the background.** Nothing else is allowed to reorder these — a "Download all"
/// on a 200-track playlist must never delay the track the user is listening to.
enum DownloadPriority: Int, Comparable, Sendable, CaseIterable {
    /// The track playing right now.
    case current = 0
    /// The track that plays next.
    case next = 1
    /// Further ahead in the play queue (lookahead).
    case upcoming = 2
    /// The user pressed Download / Download all. Background work by definition: they are not
    /// waiting on it to hear anything.
    case explicit = 3

    /// `current` and `next` are what the reserved playback lane exists for.
    var usesPlaybackLane: Bool { self <= .next }

    /// Playback-critical work is retried hard and forever; bulk work backs off and parks.
    var maxAttempts: Int { usesPlaybackLane ? Int.max : 8 }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One track waiting for, or currently holding, a download slot.
struct PendingDownload: Sendable, Equatable {
    let key: String
    var track: AudioTrack
    var priority: DownloadPriority
    /// Submission order, so equal priorities keep a stable FIFO among themselves.
    var sequence: Int
    /// Failed attempts so far. Drives the backoff and the give-up decision.
    var attempts: Int = 0
    /// Not eligible to start before this instant (backoff after a failure).
    var readyAt: Date = .distantPast
    /// The user explicitly asked for this file, so it survives play-queue changes and its
    /// failure is worth telling them about.
    var isExplicit: Bool = false

    static func == (a: Self, b: Self) -> Bool {
        a.key == b.key && a.priority == b.priority && a.sequence == b.sequence
            && a.attempts == b.attempts && a.readyAt == b.readyAt && a.isExplicit == b.isExplicit
    }
}

/// What the driver should do with a track that just failed.
enum DownloadFailureOutcome: Sendable, Equatable {
    /// Requeued; it will become eligible again at this instant.
    case retryScheduled(at: Date)
    /// This track will never succeed (deleted, undecodable container) or has spent its attempts.
    /// **Only this one track is dropped** — the queue keeps running.
    case givenUp
}

/// The scheduling brain behind the download queue: what starts next, in what order, and what
/// happens when something fails.
///
/// Deliberately **pure** — no backend, no tasks, no clock of its own (every entry point takes
/// `now`). That is what makes the two rules that actually matter testable without a network:
///
/// 1. **Playback outranks everything.** `current` and `next` also get a reserved lane, so they
///    start even when a bulk download has saturated the shared pool.
/// 2. **No failure may stop the pipeline.** A failed track is requeued with backoff, or — if it
///    can never succeed — dropped on its own. Neither outcome touches any other track, and
///    `nextAdmissible` keeps handing out work either way.
///
/// The driver (`TelegramService+Downloads`) owns the tasks and the backend; it asks this type
/// what to do and reports back what happened.
@MainActor
final class DownloadScheduler {

    /// Slots anything may use.
    let maxConcurrent: Int
    /// Extra slots only `current`/`next` may use, so bulk work can never starve playback.
    let maxPlaybackLane: Int

    private(set) var pending: [PendingDownload] = []
    /// In-flight downloads occupying a **shared pool** slot.
    private(set) var activeKeys: Set<String> = []
    /// In-flight downloads occupying a **reserved playback lane** slot. Disjoint from `activeKeys`:
    /// a slot is one or the other, never both. That is what makes the lane genuinely *additional*
    /// capacity — playback does not compete with bulk work for the shared pool at all.
    private(set) var activePlaybackKeys: Set<String> = []
    /// Entries handed out by `start(_:)`, kept so `didFail` can requeue one with its attempt
    /// history rather than resetting its backoff on every retry.
    private var inFlight: [String: PendingDownload] = [:]
    private var nextSequence = 0

    /// Backoff schedule after a failure. Playback-critical work retries fast (the user is
    /// listening); bulk work spreads out so a dead link costs nothing.
    private static let playbackBackoff: [TimeInterval] = [0.5, 1, 2, 4, 8]
    private static let bulkBackoff: [TimeInterval] = [2, 5, 15, 30, 60]

    init(maxConcurrent: Int = 3, maxPlaybackLane: Int = 2) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxPlaybackLane = max(1, maxPlaybackLane)
    }

    /// Everything in flight, across both lanes.
    var activeCount: Int { activeKeys.count + activePlaybackKeys.count }
    /// In-flight downloads holding a shared-pool slot.
    var sharedCount: Int { activeKeys.count }
    /// In-flight downloads holding a reserved playback-lane slot.
    var activePlaybackCount: Int { activePlaybackKeys.count }
    var pendingCount: Int { pending.count }

    func isActive(_ key: String) -> Bool { activeKeys.contains(key) || activePlaybackKeys.contains(key) }
    func isQueued(_ key: String) -> Bool { pending.contains { $0.key == key } || isActive(key) }

    /// What we know about a track: its queued entry, or — once started — the one in flight. Callers
    /// need the in-flight entry to report a failure against it, so this deliberately covers both.
    func entry(_ key: String) -> PendingDownload? {
        pending.first { $0.key == key } ?? inFlight[key]
    }

    // MARK: - Submitting work

    /// Queue a track, or raise an already-queued one to a higher priority.
    ///
    /// Priority only ever moves **up** here: a track that is both the next song and a pending
    /// "Download all" entry is scheduled as the next song. Demotion is the play queue's job
    /// (`setPlaybackPlan`), never a side effect of submitting.
    func submit(_ track: AudioTrack, priority: DownloadPriority, now: Date = Date()) {
        let key = track.remoteUniqueId
        let explicit = priority == .explicit
        if let index = pending.firstIndex(where: { $0.key == key }) {
            pending[index].track = track
            pending[index].isExplicit = pending[index].isExplicit || explicit
            if priority < pending[index].priority {
                pending[index].priority = priority
                // Promoted into the playback lane: a bulk backoff must not keep the song the
                // user is waiting on parked for another minute.
                if priority.usesPlaybackLane { pending[index].readyAt = min(pending[index].readyAt, now) }
            }
            sortPending()
            return
        }
        // Already running. We can't move a live transfer between lanes, but the *record* must
        // still be promoted: it is what `entry(_:)` reports (so a bulk "Stop" can tell that
        // playback now needs this file and leave it alone) and what a failure is retried under.
        if isActive(key) {
            if var flight = inFlight[key] {
                flight.isExplicit = flight.isExplicit || explicit
                if priority < flight.priority { flight.priority = priority }
                inFlight[key] = flight
            }
            return
        }
        nextSequence += 1
        pending.append(PendingDownload(key: key, track: track, priority: priority,
                                       sequence: nextSequence, isExplicit: explicit))
        sortPending()
    }

    /// Queue many tracks at one priority — a chat's "Download all". Sorts once at the end rather
    /// than once per track, which for a few hundred tracks is the difference between a visible
    /// main-actor stall and nothing at all.
    func submitAll(_ tracks: [AudioTrack], priority: DownloadPriority, now: Date = Date()) {
        guard !tracks.isEmpty else { return }
        let explicit = priority == .explicit
        var index = Dictionary(uniqueKeysWithValues: pending.enumerated().map { ($1.key, $0) })
        for track in tracks {
            let key = track.remoteUniqueId
            if let i = index[key] {
                pending[i].track = track
                pending[i].isExplicit = pending[i].isExplicit || explicit
                if priority < pending[i].priority {
                    pending[i].priority = priority
                    if priority.usesPlaybackLane { pending[i].readyAt = min(pending[i].readyAt, now) }
                }
                continue
            }
            if isActive(key) {
                if var flight = inFlight[key] {
                    flight.isExplicit = flight.isExplicit || explicit
                    if priority < flight.priority { flight.priority = priority }
                    inFlight[key] = flight
                }
                continue
            }
            nextSequence += 1
            index[key] = pending.count
            pending.append(PendingDownload(key: key, track: track, priority: priority,
                                           sequence: nextSequence, isExplicit: explicit))
        }
        sortPending()
    }

    /// Declare what playback needs, in play order: `ordered[0]` is the playing track, `ordered[1]`
    /// the one after it, the rest are lookahead.
    ///
    /// Anything that fell out of the plan and was not explicitly requested is dropped — the user
    /// skipped past it, so chasing it is wasted bandwidth. Returns those keys so the driver can
    /// cancel their tasks. It deliberately does **not** mean "delete the bytes": TDLib keeps the
    /// partial file, and skipping back onto the track resumes instead of starting over.
    @discardableResult
    func setPlaybackPlan(_ ordered: [AudioTrack], now: Date = Date()) -> [String] {
        let planKeys = Set(ordered.map(\.remoteUniqueId))

        // Drop non-explicit entries that are no longer part of the plan.
        var dropped: [String] = []
        pending.removeAll { entry in
            guard !entry.isExplicit, entry.priority.usesPlaybackLane || entry.priority == .upcoming,
                  !planKeys.contains(entry.key) else { return false }
            dropped.append(entry.key)
            return true
        }
        // Playback can occupy either lane, including a bulk transfer promoted while running.
        // Ownership, rather than the occupied slot, decides whether moving on cancels it.
        for (key, entry) in inFlight where !entry.isExplicit && !planKeys.contains(key) {
            if entry.priority.usesPlaybackLane || entry.priority == .upcoming {
                dropped.append(key)
            }
        }

        for (index, track) in ordered.enumerated() {
            let priority: DownloadPriority = index == 0 ? .current : (index == 1 ? .next : .upcoming)
            submit(track, priority: priority, now: now)
        }
        return dropped
    }

    /// Release bulk ownership without interrupting a transfer playback still needs.
    func removeExplicitRequest(_ key: String) {
        if let index = pending.firstIndex(where: { $0.key == key }) {
            pending[index].isExplicit = false
        }
        if var entry = inFlight[key] {
            entry.isExplicit = false
            inFlight[key] = entry
        }
    }

    /// Forget a track entirely (cancelled, removed, or already on disk).
    func cancel(_ key: String) {
        pending.removeAll { $0.key == key }
        activeKeys.remove(key)
        activePlaybackKeys.remove(key)
        inFlight[key] = nil
    }

    func removeAll() {
        pending.removeAll()
        activeKeys.removeAll()
        activePlaybackKeys.removeAll()
        inFlight.removeAll()
    }

    // MARK: - Admission

    /// The next track that may start right now, or `nil` when every lane is full (or everything
    /// left is still backing off).
    ///
    /// Two lanes: the shared pool anything may use, and a reserved lane only `current`/`next` may
    /// use. Playback work takes the reserved lane **first** and only falls back to the shared pool
    /// when the lane is full, so a "Download all" saturating the pool cannot delay the song that is
    /// playing — and bulk work can never occupy the lane.
    func nextAdmissible(now: Date = Date()) -> PendingDownload? {
        let sharedHasRoom = activeKeys.count < maxConcurrent
        let laneHasRoom = activePlaybackKeys.count < maxPlaybackLane
        // `pending` is kept sorted, so the first eligible entry is by definition the most urgent.
        return pending.first { entry in
            guard entry.readyAt <= now else { return false }
            if entry.priority.usesPlaybackLane, laneHasRoom { return true }
            return sharedHasRoom
        }
    }

    /// Mark the entry as started and hand it back. Pairs with `didFinish`/`didFail`.
    ///
    /// The entry leaves `pending` but is kept aside, so a failure can requeue it with its attempt
    /// history intact rather than starting its backoff over from zero every time.
    @discardableResult
    func start(_ key: String) -> PendingDownload? {
        guard let index = pending.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = pending.remove(at: index)
        if entry.priority.usesPlaybackLane, activePlaybackKeys.count < maxPlaybackLane {
            activePlaybackKeys.insert(key)
        } else {
            activeKeys.insert(key)
        }
        inFlight[key] = entry
        return entry
    }

    /// Take the next admissible entry and mark it started, in one step.
    func startNext(now: Date = Date()) -> PendingDownload? {
        guard let candidate = nextAdmissible(now: now) else { return nil }
        return start(candidate.key)
    }

    // MARK: - Completion

    func didFinish(_ key: String) {
        activeKeys.remove(key)
        activePlaybackKeys.remove(key)
        inFlight[key] = nil
        pending.removeAll { $0.key == key }
    }

    /// Record a failure and decide this one track's fate. **Never** affects any other entry:
    /// whatever comes back, the caller goes straight on to `startNext`.
    ///
    /// A permanent failure (deleted message, container we can't decode) is dropped at once —
    /// retrying it would only burn the link. Everything else is requeued with backoff, and
    /// playback-critical work is retried without an attempt ceiling, because giving up on the
    /// song the user is listening to is exactly the failure mode we refuse to have.
    @discardableResult
    func didFail(_ key: String, error: Error, now: Date = Date()) -> DownloadFailureOutcome {
        activeKeys.remove(key)
        activePlaybackKeys.remove(key)
        guard var entry = inFlight.removeValue(forKey: key) ?? pending.first(where: { $0.key == key }) else {
            return .givenUp
        }
        pending.removeAll { $0.key == key }

        guard Self.isWorthRetrying(error) else { return .givenUp }
        entry.attempts += 1
        guard entry.attempts < entry.priority.maxAttempts else { return .givenUp }
        entry.readyAt = now.addingTimeInterval(Self.backoff(for: entry))
        pending.append(entry)
        sortPending()
        return .retryScheduled(at: entry.readyAt)
    }

    /// Keys playback needs right now — queued or in flight. The audio cache must never evict
    /// these: deleting the playing track's file would be a spectacular own goal.
    var playbackProtectedKeys: Set<String> {
        var keys = activePlaybackKeys
        for entry in pending where entry.priority.usesPlaybackLane { keys.insert(entry.key) }
        for (key, entry) in inFlight where entry.priority.usesPlaybackLane { keys.insert(key) }
        return keys
    }

    /// When the pump should wake up to pick up a backed-off entry, or `nil` if there is nothing
    /// waiting on a clock.
    func nextWakeUp(now: Date = Date()) -> Date? {
        pending.filter { $0.readyAt > now }.map(\.readyAt).min()
    }

    /// The link came back — clear every backoff so parked work resumes immediately.
    func revive(now: Date = Date()) {
        for index in pending.indices where pending[index].readyAt > now {
            pending[index].readyAt = now
            pending[index].attempts = 0
        }
        sortPending()
    }

    // MARK: - Internals

    /// Most-urgent first: priority, then submission order. Kept sorted on every mutation so
    /// admission is a single scan rather than a sort per call.
    private func sortPending() {
        pending.sort { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            return a.sequence < b.sequence
        }
    }

    private static func backoff(for entry: PendingDownload) -> TimeInterval {
        let table = entry.priority.usesPlaybackLane ? playbackBackoff : bulkBackoff
        // Clamped at both ends: `didFail` always increments first, but a crash in the download
        // path is the one thing that really would stop the music.
        return table[min(max(entry.attempts - 1, 0), table.count - 1)]
    }

    /// A failure that can never succeed is not worth a slot. Everything else — a dropped link, a
    /// timeout, a stalled transfer, an error we don't recognise — gets another go: on a mobile
    /// link that is the normal case, not a real failure.
    static func isWorthRetrying(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let telegram = error as? TelegramError {
            switch telegram {
            case .unsupportedFormat, .deleted, .missingCredentials: return false
            case .backend, .transient, .notReady: return true
            }
        }
        return true
    }
}

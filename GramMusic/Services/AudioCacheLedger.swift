import Foundation

/// One audio file on disk, and why it is there.
struct CachedAudioFile: Codable, Sendable, Equatable {
    let key: String          // remoteUniqueId
    var bytes: Int64
    /// Last time this file was played or downloaded — the LRU key.
    var lastUsed: Date
    /// TDLib's persistent remote file id, kept so the file can still be **deleted** later.
    ///
    /// Without it an eviction could only delete files whose track it happened to find in some
    /// list still in memory; everything else was dropped from the ledger while its bytes stayed on
    /// disk forever — a leak in exactly the mechanism meant to prevent one. Defaulted so ledgers
    /// written before this field decode.
    var remoteFileId: String = ""
}

/// What the on-disk audio store is allowed to hold, and what to drop when it is full.
///
/// The distinction this type exists to enforce: **a track you downloaded and a track you merely
/// played are not the same thing.**
///
/// - A track the user explicitly downloaded is *kept*. They asked for it, possibly for a flight.
///   It is never evicted, never counted against the cache budget, and it is what the "Downloaded"
///   library lists.
/// - A track that landed on disk only because it was played is a *cache* entry. It still plays
///   offline — it is a real file — but it lives under a byte budget and the least-recently-played
///   entries are dropped when that budget is exceeded.
///
/// Before this existed there was no eviction of audio at all, anywhere: every track ever played
/// stayed on disk forever and was listed as "Downloaded". Listening to a few hundred songs quietly
/// consumed a few gigabytes that the user had no way to reclaim short of deleting the app.
///
/// Pure — no file system, no backend, `now` is injected — so the policy is unit-testable and the
/// driver (`TelegramService`) does the deleting.
@MainActor
final class AudioCacheLedger {

    /// Cache entries only. Explicit downloads are tracked separately (`protectedKeys`) and are
    /// deliberately *not* in here: they have no budget and no expiry.
    private(set) var entries: [String: CachedAudioFile] = [:]
    /// Transiently un-evictable — chiefly whatever playback needs right now. These keep their
    /// entry: protection means "don't delete this yet", **not** "forget it exists". Dropping the
    /// record instead (which is what this used to do) left the file on disk with nothing tracking
    /// it the moment playback moved on — an untracked file that could never be evicted again.
    private(set) var protectedKeys: Set<String> = []
    /// Explicit downloads. These are *not* cache at all: no entry, no budget, no expiry, and
    /// `record` refuses to re-admit them.
    private(set) var downloadKeys: Set<String> = []

    /// Byte budget for cache entries. Explicit downloads do not count against it.
    var budget: Int64

    /// How long an untouched cache entry survives. Size is not the only reason to let a file go:
    /// a track played once months ago is dead weight even on a phone with room to spare, and the
    /// user's expectation for something they never asked to keep is that it goes away on its own.
    var maxAge: TimeInterval

    /// Default cache budget. Big enough that ordinary listening never evicts anything the user
    /// would notice, small enough that the app is not quietly the largest thing on the phone.
    // `nonisolated`: these are used as default arguments, which are evaluated outside the actor.
    nonisolated static let defaultBudget: Int64 = 2 * 1024 * 1024 * 1024   // 2 GB
    nonisolated static let defaultMaxAge: TimeInterval = 30 * 24 * 60 * 60   // 30 days

    init(budget: Int64 = AudioCacheLedger.defaultBudget,
         maxAge: TimeInterval = AudioCacheLedger.defaultMaxAge) {
        self.budget = budget
        self.maxAge = maxAge
    }

    /// Total bytes held by evictable cache entries.
    ///
    /// Maintained incrementally rather than summed on demand: Settings ▸ Storage reads it from a
    /// view body, and a `reduce` over every entry on each render is work for a number that only
    /// changes when a file lands or leaves.
    private(set) var usedBytes: Int64 = 0
    var count: Int { entries.count }

    func contains(_ key: String) -> Bool { entries[key] != nil }
    func entry(_ key: String) -> CachedAudioFile? { entries[key] }

    // MARK: - Recording

    /// A file landed on disk because the track was played. Idempotent; re-recording refreshes its
    /// LRU position.
    func record(_ key: String, bytes: Int64, remoteFileId: String = "", now: Date = Date()) {
        // Only an explicit *download* is barred. A merely-protected key (the playing track) is
        // still cache and must be recorded, or its file is never accounted for and never evicted.
        guard !downloadKeys.contains(key) else { return }
        if var existing = entries[key] {
            existing.lastUsed = now
            if bytes > 0 {
                usedBytes += bytes - existing.bytes
                existing.bytes = bytes
            }
            if !remoteFileId.isEmpty { existing.remoteFileId = remoteFileId }
            entries[key] = existing
        } else {
            let size = max(0, bytes)
            entries[key] = CachedAudioFile(key: key, bytes: size, lastUsed: now,
                                           remoteFileId: remoteFileId)
            usedBytes += size
        }
    }

    /// Mark a cache entry as used right now, so listening to something keeps it alive.
    func touch(_ key: String, now: Date = Date()) {
        guard var existing = entries[key] else { return }
        existing.lastUsed = now
        entries[key] = existing
    }

    /// Promote a cached file to an explicit download: it stops counting against the budget and can
    /// no longer be evicted. What happens when the user taps Download on something already cached.
    func promote(_ key: String) {
        downloadKeys.insert(key)
        protectedKeys.insert(key)
        drop(key)
    }

    /// The user removed an explicit download; it is no longer protected. (The file itself is
    /// deleted by the caller, so it does not become a cache entry.)
    func demote(_ key: String) {
        downloadKeys.remove(key)
        protectedKeys.remove(key)
        drop(key)
    }

    /// Replace the transiently-protected set — the tracks playback needs right now, plus the
    /// explicit downloads (which have no entry anyway). Deliberately does **not** drop entries.
    func setProtected(_ keys: Set<String>) {
        protectedKeys = keys
    }

    func forget(_ key: String) { drop(key) }

    func removeAll() {
        entries.removeAll()
        protectedKeys.removeAll()
        downloadKeys.removeAll()
        usedBytes = 0
    }

    /// Remove an entry, keeping the running total honest. Every removal goes through here — a
    /// bare `entries[key] = nil` would leave `usedBytes` counting a file that is gone.
    private func drop(_ key: String) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        usedBytes -= removed.bytes
    }

    // MARK: - Eviction

    /// Keys to delete, least-recently-played first: everything past `maxAge`, plus however much
    /// more it takes to get back under `budget`.
    ///
    /// Protected keys are never returned — an explicit download and the track currently playing
    /// are both off limits, however old they are.
    func keysToEvict(now: Date = Date()) -> [String] {
        let oldest = entries.values
            .filter { !protectedKeys.contains($0.key) }
            .sorted { $0.lastUsed < $1.lastUsed }

        var victims: [String] = []
        var freed: Int64 = 0

        // 1. Anything the user hasn't touched in a long time goes regardless of how full we are.
        for file in oldest where now.timeIntervalSince(file.lastUsed) > maxAge {
            victims.append(file.key)
            freed += file.bytes
        }

        // 2. Then, if still over budget, keep taking the least-recently-played.
        var over = usedBytes - freed - budget
        guard over > 0 else { return victims }
        let expired = Set(victims)
        for file in oldest where !expired.contains(file.key) {
            guard over > 0 else { break }
            victims.append(file.key)
            over -= file.bytes
        }
        return victims
    }

    /// Everything evictable, for a "Clear cache" action. Protected keys survive.
    func allEvictableKeys() -> [String] {
        entries.keys.filter { !protectedKeys.contains($0) }
    }

    // MARK: - Persistence

    /// The ledger has to survive relaunch or the budget resets to zero every cold start and
    /// nothing is ever evicted — which is the bug it exists to fix, reintroduced.
    func snapshot() -> [CachedAudioFile] { Array(entries.values) }

    func restore(_ files: [CachedAudioFile]) {
        entries = Dictionary(files.map { ($0.key, $0) }, uniquingKeysWith: { a, b in
            a.lastUsed >= b.lastUsed ? a : b
        })
        usedBytes = entries.values.reduce(0) { $0 + $1.bytes }
        // Anything already known to be an explicit download isn't cache, whatever the saved
        // ledger said. `drop` so the total stays in step.
        for key in downloadKeys { drop(key) }
    }
}

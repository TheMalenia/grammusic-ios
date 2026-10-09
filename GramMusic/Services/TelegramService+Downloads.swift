import Foundation
import SwiftData

/// Download queue and on-disk state for `TelegramService`.
///
/// Split out of `TelegramService.swift`, which had grown past 1,900 lines. This half is the
/// **driver** around `DownloadScheduler`: the scheduler decides *what* downloads next and what a
/// failure means, this file owns the tasks, the backend calls and the observable
/// `downloadedIds` / `downloadingIds` / `downloadProgressByTrack` mirrors the UI reads. Stored
/// state still lives on the main type; see the "Downloads" section there.
///
/// Two rules run through everything here:
/// - **Playback outranks everything.** The playing track, then the next one, then the lookahead,
///   then bulk work — and the first two also get a reserved lane so a "Download all" can never
///   delay them (`DownloadPriority`).
/// - **No failure stops the pipeline.** A failed track is requeued with backoff or dropped on its
///   own; either way the pump immediately starts the next one. Nothing here can leave the queue
///   stalled, and nothing here writes `lastError` (the playback banner).
@MainActor
extension TelegramService {

    // MARK: - Downloads

    func isDownloaded(_ track: AudioTrack) -> Bool { downloadedIds.contains(track.remoteUniqueId) }
    func isDownloading(_ track: AudioTrack) -> Bool { downloadingIds.contains(track.remoteUniqueId) }
    /// Live download fraction (0…1) for a track, or `nil` when no ring should be shown.
    ///
    /// The ring means **"this file is being kept"** — so it tracks where the finished file will be
    /// filed, not who asked for it. Two cases show it: an explicit download, and *any* download
    /// while "Keep everything I play" is on, because that setting makes every played track land in
    /// the Downloaded library. Without the second case the button sat empty for the whole transfer
    /// and then snapped straight to "downloaded", which reads as nothing happening followed by
    /// magic.
    ///
    /// Deliberately **not** done by adding these keys to `explicitDownloadIds`. That set answers a
    /// different question — *who owns this transfer* — and three behaviours key off it: the bulk
    /// "Stop (N)" button's count and cancel, and `planPlaybackDownloads`' decision about what to
    /// cancel when the queue moves on. Marking playback transfers explicit to get a ring made the
    /// bulk button offer to cancel the playing track and stopped the player cancelling its own
    /// downloads when closed. Display and ownership are separate questions; keep them separate.
    func downloadFraction(for track: AudioTrack) -> Double? {
        let key = track.remoteUniqueId
        guard explicitDownloadIds.contains(key) || autoDownloadPlayed else { return nil }
        return downloadProgressByTrack[key]
    }

    /// A chat's / playlist's "Download all". Submitted as one batch so a few hundred tracks cost
    /// one sort rather than one per track.
    func downloadAll(_ tracks: [AudioTrack]) {
        let wanted = tracks.filter { !downloadedIds.contains($0.remoteUniqueId) }
        guard !wanted.isEmpty else { return }
        for track in wanted {
            let key = track.remoteUniqueId
            canceledDownloadIds.remove(key)
            explicitDownloadIds.insert(key)
            downloadingIds.insert(key)
            if downloadProgressByTrack[key] == nil { downloadProgressByTrack[key] = 0 }
            activeDownloadTracks[key] = track
        }
        downloads.submitAll(wanted, priority: .explicit)
        processDownloadQueue()
    }

    /// Size of a completed download on disk, for the cache ledger's budget.
    static func fileSize(at url: URL) -> Int64 {
        let value = try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
        return (value as? NSNumber)?.int64Value ?? 0
    }

    /// Whether this track is downloading because the **user asked for it**, as opposed to because
    /// playback needs it. The two must not be conflated in the UI: "Stop (N)" counting the playing
    /// track and then cancelling it is the bulk button reaching into the music.
    func isExplicitlyDownloading(_ track: AudioTrack) -> Bool {
        let key = track.remoteUniqueId
        return explicitDownloadIds.contains(key) && downloadingIds.contains(key)
    }

    /// Stop the user's bulk download of `tracks`.
    ///
    /// **Only explicit work**, and never a track in the playback plan: those are downloading
    /// because playback needs them, not because the user pressed Download all, and cancelling them
    /// from a chat screen would interrupt the music. Partial bytes are kept (see
    /// `cancelTransientDownload`) so resuming costs nothing.
    func stopDownloads(_ tracks: [AudioTrack]) {
        for track in tracks where isExplicitlyDownloading(track) {
            let key = track.remoteUniqueId
            explicitDownloadIds.remove(key)
            downloads.removeExplicitRequest(key)
            // Playback retains the transfer, but the bulk job no longer owns it. Its progress
            // ring remains visible when "Keep everything I play" is enabled.
            if playbackPlanKeys.contains(key) { continue }
            cancelTransientDownload(key: key)
        }
    }

    /// User-initiated download for a single track. Explicit work is never dropped when the play
    /// queue moves on, and its failures are the only ones worth a notice.
    func download(_ track: AudioTrack) {
        enqueueDownload(track, priority: .explicit)
    }

    /// Queue a track at `priority`, or raise an already-queued one to it.
    func enqueueDownload(_ track: AudioTrack, priority: DownloadPriority = .explicit) {
        let key = track.remoteUniqueId
        guard !downloadedIds.contains(key) else { return }
        canceledDownloadIds.remove(key)   // a fresh download supersedes any prior cancel
        // **Only what the user actually asked for is "explicit".** "Keep everything I play"
        // decides where a *finished* file is filed (Downloaded vs. cache) — that is applied at
        // completion, not here. Letting it mark in-flight playback transfers as explicit made the
        // whole distinction collapse, because the setting is on by default: the progress ring
        // appeared on every track the user merely played, the chat screen's bulk "Stop (N)" button
        // counted (and would cancel) the playing track, and dropping the playback plan stopped
        // cancelling anything, so closing the player kept downloading.
        if priority == .explicit { explicitDownloadIds.insert(key) }
        downloadingIds.insert(key)
        if downloadProgressByTrack[key] == nil { downloadProgressByTrack[key] = 0 }
        activeDownloadTracks[key] = track
        downloads.submit(track, priority: priority)
        processDownloadQueue()
    }

    /// Tell the download queue what playback needs, in play order: `ordered[0]` is the track
    /// playing right now, `ordered[1]` the one after it, the rest are the lookahead.
    ///
    /// This is the single entry point for playback-driven downloads. The player used to *also*
    /// prefetch its neighbours straight through `fileProvider`, which bypassed the queue, both
    /// lanes and the concurrency cap entirely — so the bound was never real, and the canceller
    /// could not stop a download it had never started.
    func planPlaybackDownloads(_ ordered: [AudioTrack]) {
        // Remembered beyond the scheduler's own queue: these stay protected from cache eviction
        // for as long as they are what playback needs, including after their download completes.
        playbackPlanKeys = Set(ordered.map(\.remoteUniqueId))
        let dropped = downloads.setPlaybackPlan(ordered)
        for key in dropped where !explicitDownloadIds.contains(key) {
            cancelTransientDownload(key: key)
        }
        for (index, track) in ordered.enumerated() {
            let key = track.remoteUniqueId
            guard !downloadedIds.contains(key) else { continue }
            let priority: DownloadPriority = index == 0 ? .current : (index == 1 ? .next : .upcoming)
            enqueueDownload(track, priority: priority)
        }
        processDownloadQueue()
    }

    /// Stop chasing a background/transient download.
    ///
    /// Stops the transfer but **keeps the bytes**. Both halves matter, and each was wrong once:
    /// - It used to `deleteFile`, throwing away every byte fetched — so skipping forward and back
    ///   re-downloaded from zero.
    /// - Then it deleted nothing *and told TDLib nothing*, so cancelling our own polling task left
    ///   TDLib happily downloading the whole file in the background. Closing a song, or tapping a
    ///   different one, kept spending the user's bandwidth on tracks nobody was waiting for —
    ///   and a completed one could then surface as playback that nobody asked for.
    ///
    /// `cancelDownload` is the right instrument: stop chasing it, keep the partial file so
    /// resuming is cheap. Deleting bytes is `removeDownload`'s job, and only the user asks for that.
    func cancelTransientDownload(key: String) {
        noteCanceled(key)
        downloadTasks[key]?.cancel()
        downloadTasks[key] = nil
        downloads.cancel(key)
        downloadingIds.remove(key)
        downloadProgressByTrack[key] = nil
        let track = activeDownloadTracks.removeValue(forKey: key)
        guard let track else { return }
        let backend = self.backend
        Task { await backend.cancelDownload(for: track) }
    }

    /// Remember that `key` was cancelled so trailing backend updates for it are swallowed.
    ///
    /// Bounded: this set gained an entry for every track the user skipped past and was only ever
    /// pruned by a completion event, so a long listening session grew it without limit. Cancelled
    /// keys only matter until the backend stops emitting for them, so keeping the most recent few
    /// hundred is more than enough.
    func noteCanceled(_ key: String) {
        canceledDownloadIds.insert(key)
        canceledDownloadOrder.append(key)
        guard canceledDownloadOrder.count > Self.maxCanceledDownloadMemory else { return }
        let overflow = canceledDownloadOrder.count - Self.maxCanceledDownloadMemory
        let evicted = canceledDownloadOrder.prefix(overflow)
        canceledDownloadOrder.removeFirst(overflow)
        // Only forget a key that hasn't been re-cancelled since.
        let stillQueued = Set(canceledDownloadOrder)
        for key in evicted where !stillQueued.contains(key) { canceledDownloadIds.remove(key) }
    }

    /// Start everything the scheduler will admit right now.
    ///
    /// Every exit from a download — success, failure, cancellation — comes back through here, so
    /// the queue cannot stall on one track's bad luck.
    func processDownloadQueue() {
        while let entry = downloads.startNext() {
            let key = entry.key
            let track = entry.track

            // Cancelled or already satisfied while it sat in the queue.
            guard !canceledDownloadIds.contains(key), !downloadedIds.contains(key) else {
                downloads.didFinish(key)
                continue
            }

            let backend = self.backend
            downloadTasks[key] = Task { [weak self] in
                do {
                    // A dropped link mid-download is the normal case on mobile, not a failure:
                    // back off and pick it up again rather than reporting it and giving up.
                    let url = try await Retry.run(.download) {
                        try await backend.ensureLocalFile(for: track)
                    }
                    guard let self, !Task.isCancelled, !self.canceledDownloadIds.contains(key) else { return }
                    downloadLog.info("Downloaded \(track.displayTitle, privacy: .public)")
                    let explicitlyRequested = self.explicitDownloadIds.contains(key)
                    self.downloads.didFinish(key)
                    self.downloadTasks[key] = nil
                    // **Only what the user asked for is a download.** This passed no `explicit:`
                    // at all, so it took the default `true` and every playback prefetch landed in
                    // the Downloaded library — which is exactly the behaviour the cache exists to
                    // replace, so nothing was ever cached and nothing was ever evicted.
                    self.markDownloaded(track,
                                        explicit: explicitlyRequested || self.autoDownloadPlayed,
                                        bytes: Self.fileSize(at: url))
                    self.processDownloadQueue()
                } catch {
                    guard let self else { return }
                    guard !self.canceledDownloadIds.contains(key) else {
                        self.downloads.didFinish(key)
                        self.processDownloadQueue()
                        return
                    }
                    self.handleDownloadFailure(track, entry: entry, error: error)
                }
            }
        }
        scheduleDownloadRetryWake()
    }

    /// One track failed. Ask the scheduler what that means for *this* track only, then keep the
    /// pipeline moving regardless of the answer.
    ///
    /// This is the rule the user cares about most: **an error must never stop downloading.** A
    /// transient failure is requeued with backoff (playback-critical work without an attempt
    /// ceiling), a permanent one is dropped alone, and either way the very next line starts the
    /// next admissible track.
    func handleDownloadFailure(_ track: AudioTrack, entry: PendingDownload, error: Error) {
        let key = track.remoteUniqueId
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        downloadTasks[key] = nil

        switch downloads.didFail(key, error: error) {
        case .retryScheduled(let at):
            downloadLog.info("Download retrying \(track.displayTitle, privacy: .public) at \(at, privacy: .public): \(reason, privacy: .public)")
            // Keep the row in its downloading state — from the user's side it *is* still
            // downloading; it's just waiting out a backoff.
            downloadingIds.insert(key)
            activeDownloadTracks[key] = track
        case .givenUp:
            finishFailedDownload(track, error: error, wasExplicit: explicitDownloadIds.contains(key))
        }
        processDownloadQueue()
    }

    /// Wake the pump when the earliest backed-off entry becomes eligible, so a requeued download
    /// actually restarts instead of sitting in the queue until something else happens to pump it.
    func scheduleDownloadRetryWake() {
        downloadRetryTask?.cancel()
        downloadRetryTask = nil
        guard let wake = downloads.nextWakeUp() else { return }
        let delay = max(0.05, wake.timeIntervalSinceNow)
        downloadRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.downloadRetryTask = nil
            self.processDownloadQueue()
        }
    }

    /// The link came back: clear every backoff so parked downloads resume at once.
    func resumeDeferredDownloads() {
        downloads.revive()
        processDownloadQueue()
    }

    /// Clear the download's session state and decide whether the user should hear about it.
    ///
    /// Only reached once the scheduler has genuinely given up on a track (a permanent failure, or
    /// a bulk download that spent its attempts). Only a download the user *asked for* is worth a
    /// notice — the rest are prefetches the player started on its own, and telling someone their
    /// prefetch of track 4 failed while track 3 plays fine is noise. Either way this writes
    /// `downloadError`, never `lastError`, so nothing here can raise the playback banner.
    func finishFailedDownload(_ track: AudioTrack, error: Error, wasExplicit: Bool) {
        let key = track.remoteUniqueId
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        downloadLog.error("Download FAILED for \(track.displayTitle, privacy: .public): \(reason, privacy: .public)")
        downloads.cancel(key)
        downloadingIds.remove(key)
        downloadProgressByTrack[key] = nil
        activeDownloadTracks[key] = nil
        explicitDownloadIds.remove(key)
        downloadTasks[key] = nil
        guard wasExplicit else { return }
        downloadError = "Couldn't download \(track.displayTitle). \(reason)"
    }

    // MARK: - The on-disk audio store

    /// A track's file finished downloading.
    ///
    /// - Parameter explicit: the user asked for this file (Download / Download all). Explicit
    ///   downloads go into the "Downloaded" library and are **kept forever**. Everything else
    ///   landed on disk only because the track was played, so it becomes a *cache* entry: still
    ///   playable offline, but counted against `AudioCacheLedger`'s budget and evicted
    ///   least-recently-played first. Conflating the two is how listening to a few hundred songs
    ///   used to consume gigabytes the user could not reclaim.
    func markDownloaded(_ track: AudioTrack, explicit: Bool = true, bytes: Int64 = 0) {
        let key = track.remoteUniqueId
        downloads.didFinish(key)
        explicitDownloadIds.remove(key)
        downloadingIds.remove(key)
        downloadProgressByTrack[key] = nil
        activeDownloadTracks[key] = nil

        guard explicit else {
            noteCachedFile(key, bytes: bytes, remoteFileId: track.remoteFileId)
            return
        }
        // Promoting a cached file to a real download: it stops counting against the budget.
        audioCache.promote(key)
        cachedIds.remove(key)
        let isNew = downloadedIds.insert(key).inserted
        if let context = modelContext {
            PlaylistService(context: context).recordDownload(track)
        }
        guard isNew else { return }
        // Drop the provisional (low-res) cover so the next lookup resolves the embedded full-res
        // cover now that the file is on disk. (The resolver self-heals too — embedded always wins
        // over a provisional — this just refreshes any cover already shown for this track.)
        Task { await provisionalCover.invalidate(key) }
    }

    /// Record a file that is on disk only because its track was played. Bills it against the cache
    /// budget and evicts the least-recently-played entries if that puts us over.
    func noteCachedFile(_ key: String, bytes: Int64, remoteFileId: String = "") {
        guard !downloadedIds.contains(key) else { return }   // explicit downloads aren't cache
        audioCache.record(key, bytes: bytes, remoteFileId: remoteFileId)
        cachedIds.insert(key)
        persistAudioCache()
        enforceAudioCacheBudget()
    }

    /// Everything that must survive an eviction, whatever the reason for it.
    ///
    /// Three groups, and each was a bug when it was missing:
    /// - **Explicit downloads**, finished *or in flight* — "Clear cache" deleting the file of a
    ///   download the user is watching complete is the opposite of what the button says.
    /// - **What playback needs right now** — the playing track and its lookahead. Note this is the
    ///   last plan the player published, not just what the scheduler still has queued: once the
    ///   playing track finishes downloading the scheduler forgets it, and it would then be a
    ///   perfectly ordinary cache entry that "Clear cache" could delete *mid-song*.
    var cacheProtectedKeys: Set<String> {
        downloadedIds
            .union(explicitDownloadIds)
            .union(downloadingIds)
            .union(playbackPlanKeys)
            .union(downloads.playbackProtectedKeys)
    }

    /// Delete the least-recently-played cached files until we are back under budget.
    func enforceAudioCacheBudget() {
        audioCache.setProtected(cacheProtectedKeys)
        let victims = audioCache.keysToEvict()
        guard !victims.isEmpty else { return }
        evictCachedFiles(victims)
    }

    /// Drop these cached files from disk. Shared by budget eviction and the explicit "Clear cache".
    func evictCachedFiles(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        let backend = self.backend
        var tracks: [AudioTrack] = []
        for key in keys {
            // Resolve *before* forgetting: the ledger entry is where the remote file id lives.
            if let track = cachedTrackLookup(key) { tracks.append(track) }
            audioCache.forget(key)
            cachedIds.remove(key)
        }
        persistAudioCache()
        guard !tracks.isEmpty else { return }
        Task.detached {
            for track in tracks { await backend.removeLocalFile(for: track) }
        }
        downloadLog.info("Evicted \(keys.count, privacy: .public) cached audio files")
    }

    /// Move every cached file into the Downloaded library — what "keep everything I play" does the
    /// moment it is switched on, so the setting applies to what is already on disk and not just to
    /// future plays.
    func promoteCachedToDownloads() {
        let keys = audioCache.allEvictableKeys()
        guard !keys.isEmpty, let context = modelContext else { return }
        let service = PlaylistService(context: context)
        for key in keys {
            guard let track = cachedTrackLookup(key) else { continue }
            audioCache.promote(key)
            cachedIds.remove(key)
            downloadedIds.insert(key)
            service.recordDownload(track)
        }
        persistAudioCache()
    }

    /// Total bytes held by evictable cached audio (explicit downloads excluded).
    var cachedAudioBytes: Int64 { audioCache.usedBytes }

    /// Drop every cached file. Backs Settings ▸ Storage ▸ Clear cache.
    ///
    /// Refreshes the protected set **first**: without that it cleared whatever happened to be
    /// protected at the last budget check, so pressing Clear cache mid-song could delete the file
    /// of the track that was playing, and could delete a download that had completed since.
    func clearAudioCache() {
        audioCache.setProtected(cacheProtectedKeys)
        evictCachedFiles(audioCache.allEvictableKeys())
    }

    /// Enough of a track to ask the backend to delete its file. Cache entries are keyed by
    /// `remoteUniqueId` alone, so the track itself is recovered from whatever list still holds it;
    /// failing that, a stub carrying the id is enough for the offline `getRemoteFile` path.
    func cachedTrackLookup(_ key: String) -> AudioTrack? {
        if let track = activeDownloadTracks[key] { return track }
        if let track = recentlyPlayed.first(where: { $0.remoteUniqueId == key }) { return track }
        if let context = modelContext,
           let ref = PlaylistService(context: context).anyTrackRef(remoteUniqueId: key) {
            return ref.audioTrack
        }
        // Nothing in memory remembers this track any more — the *normal* case for an old cache
        // entry, and it used to mean the file was simply abandoned on disk: forgotten by the
        // ledger, still taking up space. The ledger keeps the remote file id for exactly this. A
        // stub carrying it is all `removeLocalFile` needs, since it resolves the file offline via
        // `getRemoteFile` — the same path rehydrated playlist tracks use.
        guard let entry = audioCache.entry(key), !entry.remoteFileId.isEmpty else { return nil }
        return AudioTrack(chatId: 0, messageId: 0, fileId: -1,
                          remoteUniqueId: key, remoteFileId: entry.remoteFileId,
                          title: "", performer: "", duration: 0)
    }

    /// Persist the ledger. Without this the budget resets to zero on every cold start and nothing
    /// is ever evicted — exactly the bug it exists to fix.
    func persistAudioCache() {
        guard let data = try? JSONEncoder().encode(audioCache.snapshot()) else { return }
        UserDefaults.standard.set(data, forKey: StorageKeys.audioCache)
    }

    /// Reload the ledger at launch and reconcile the budget.
    func restoreAudioCache() {
        let budget = UserDefaults.standard.object(forKey: StorageKeys.audioCacheBudget) as? Int64
        audioCache.budget = budget ?? AudioCacheLedger.defaultBudget
        guard let data = UserDefaults.standard.data(forKey: StorageKeys.audioCache),
              let files = try? JSONDecoder().decode([CachedAudioFile].self, from: data) else { return }
        audioCache.restore(files)
        cachedIds = Set(files.map(\.key)).subtracting(downloadedIds)
    }

    /// Change the cache budget (Settings ▸ Storage) and apply it immediately.
    func setAudioCacheBudget(_ bytes: Int64) {
        audioCache.budget = bytes
        UserDefaults.standard.set(bytes, forKey: StorageKeys.audioCacheBudget)
        enforceAudioCacheBudget()
    }

    /// Remove a downloaded track: drop it from the Downloaded library, clear session state, and
    /// delete the on-disk file via the backend. Inverse of `download(_:)`. Idempotent.
    /// Whether taking a track out of Downloaded **keeps its file**, as an evictable cache entry,
    /// instead of deleting it.
    ///
    /// Two cases where deleting is the wrong reading of the tap:
    /// **Playback still needs it.** Deleting the file of the track that is playing (or is next up)
    /// out from under the player is never what the user meant.
    ///
    /// "Keep everything I play" deliberately does *not* appear here. That setting is about tracks
    /// the user **played**; a track they explicitly downloaded and then explicitly un-downloaded is
    /// neither, and since the setting is on by default, honouring it here meant `removeDownload`
    /// almost never deleted anything — so the button freed no space and the bytes were re-filed as
    /// cache instead of going away.
    func removalKeepsFile(_ key: String) -> Bool {
        playbackPlanKeys.contains(key)
    }

    /// Take a track out of the Downloaded library. Inverse of `download(_:)`. Idempotent.
    ///
    /// Whether the audio goes with it is `removalKeepsFile`'s call. A *partial* download is always
    /// cancelled rather than demoted — there is no complete file to keep.
    func removeDownload(_ track: AudioTrack) {
        let key = track.remoteUniqueId
        guard downloadedIds.contains(key) || downloadingIds.contains(key) else { return }
        let wasComplete = downloadedIds.contains(key)
        let keepFile = wasComplete && removalKeepsFile(key)

        explicitDownloadIds.remove(key)
        // Mute trailing backend updates so a `deleteFile` or partial-file update can't resurrect
        // the download. Not when we are keeping the file: it stays legitimately on disk.
        if !keepFile { noteCanceled(key) }
        downloadTasks[key]?.cancel()
        downloadTasks[key] = nil
        downloads.cancel(key)
        downloadedIds.remove(key)
        downloadingIds.remove(key)
        downloadProgressByTrack[key] = nil
        activeDownloadTracks[key] = nil
        audioCache.demote(key)   // no longer an explicit download, whatever happens to the bytes
        cachedIds.remove(key)

        if let context = modelContext {
            PlaylistService(context: context).removeDownload(track)
        }

        let backend = self.backend
        guard keepFile else {
            persistAudioCache()
            Task.detached { await backend.removeLocalFile(for: track) }   // TDLib `deleteFile` halts the download
            return
        }
        // Stays on disk, now as ordinary cache. Its size has to be read back from the file: the
        // ledger deliberately stops tracking bytes the moment something becomes a download.
        Task { [weak self] in
            let bytes = await backend.localPlayableURL(for: track).map(Self.fileSize(at:)) ?? 0
            self?.noteCachedFile(key, bytes: bytes, remoteFileId: track.remoteFileId)
        }
    }
}

import XCTest
@testable import GramMusic

/// The service-level half of the download pipeline: how `TelegramService` drives
/// `DownloadScheduler` (whose own ordering and failure rules are pinned in
/// `DownloadSchedulerTests`), and the error surface that keeps a failed download from ever
/// dressing itself up as a playback failure.
@MainActor
final class DownloadLaneTests: XCTestCase {

    private func makeService() -> TelegramService {
        TelegramService(backend: MockTelegramBackend())
    }

    private func track(_ id: String) -> AudioTrack {
        AudioTrack(chatId: 0, messageId: 0, fileId: 1, remoteUniqueId: id, remoteFileId: "r-\(id)",
                   title: "Song \(id)", performer: "Artist", duration: 100, fileName: "\(id).mp3")
    }

    // MARK: - Playback drives the queue

    func test_playbackPlan_ordersTheQueuePlayingFirst() {
        let service = makeService()
        service.planPlaybackDownloads([track("playing"), track("next"), track("later")])

        XCTAssertEqual(service.downloads.entry("playing")?.priority, .current)
        XCTAssertEqual(service.downloads.entry("next")?.priority, .next)
        XCTAssertEqual(service.downloads.entry("later")?.priority, .upcoming)
        XCTAssertEqual(service.downloads.activePlaybackCount, 2,
                       "the playing track and the next one hold the reserved lane")
    }

    func test_playbackPlan_marksTheTracksAsDownloadingForTheUI() {
        let service = makeService()
        service.planPlaybackDownloads([track("a"), track("b")])
        XCTAssertTrue(service.isDownloading(track("a")))
        XCTAssertTrue(service.isDownloading(track("b")))
    }

    func test_playbackPlan_skipsWhatIsAlreadyOnDisk() {
        let service = makeService()
        service.downloadedIds.insert("have")
        service.planPlaybackDownloads([track("have"), track("need")])

        XCTAssertFalse(service.downloads.isQueued("have"), "no point downloading it twice")
        XCTAssertTrue(service.downloads.isQueued("need"))
    }

    // The user skipping forward must not throw away work they may skip straight back onto.
    func test_droppingATransientDownload_doesNotDeleteWhatWasAlreadyFetched() async {
        let backend = MockTelegramBackend()
        let service = TelegramService(backend: backend)
        service.planPlaybackDownloads([track("a"), track("b")])
        service.cancelTransientDownload(key: "a")
        await Task.yield()

        XCTAssertFalse(service.isDownloading(track("a")), "we stop chasing it")
        let removed = await backend.removedLocalFileIds
        XCTAssertFalse(removed.contains("a"),
                       "but its partial bytes stay on disk, so skipping back resumes rather than restarts")
    }

    // An explicit download is the user's, not the play queue's — moving on must not cancel it.
    func test_explicitDownload_survivesThePlayQueueMovingOn() {
        let service = makeService()
        service.download(track("wanted"))
        service.planPlaybackDownloads([track("a"), track("b")])
        service.planPlaybackDownloads([track("b"), track("c")])

        XCTAssertTrue(service.downloads.isQueued("wanted"))
        XCTAssertTrue(service.explicitDownloadIds.contains("wanted"))
    }

    // MARK: - Bulk work vs. the music

    // "Download all" and the playing track both show as downloading, but the chat screen's
    // "Stop (N)" button is the *bulk* button — counting the playing track there, and then
    // cancelling it, is that button reaching into the music.
    func test_stopDownloads_leavesThePlayingTrackAlone() {
        let service = makeService()
        service.planPlaybackDownloads([track("playing"), track("next")])
        service.downloadAll([track("bulk")])

        service.stopDownloads([track("playing"), track("next"), track("bulk")])

        XCTAssertTrue(service.downloads.isQueued("playing"), "the music keeps downloading")
        XCTAssertTrue(service.downloads.isQueued("next"))
        XCTAssertFalse(service.downloads.isQueued("bulk"), "only the user's bulk work stops")
    }

    func test_isExplicitlyDownloading_countsOnlyWhatTheUserAskedFor() {
        let service = makeService()
        service.planPlaybackDownloads([track("playing")])
        service.downloadAll([track("bulk")])

        XCTAssertFalse(service.isExplicitlyDownloading(track("playing")),
                       "a playback download is not part of the user's bulk job")
        XCTAssertTrue(service.isExplicitlyDownloading(track("bulk")))
    }

    // A track that is both the user's download *and* what plays next must survive Stop: playback
    // still needs it, so it is demoted out of the bulk job rather than cancelled.
    func test_stoppingADownloadPlaybackAlsoNeeds_demotesInsteadOfCancelling() {
        let service = makeService()
        service.downloadAll([track("shared")])
        service.planPlaybackDownloads([track("shared")])

        service.stopDownloads([track("shared")])

        XCTAssertTrue(service.downloads.isQueued("shared"))
        XCTAssertFalse(service.explicitDownloadIds.contains("shared"), "no longer part of the bulk job")
    }

    func test_downloadAll_skipsWhatIsAlreadyOnDisk() {
        let service = makeService()
        service.downloadedIds.insert("have")
        service.downloadAll([track("have"), track("need")])

        XCTAssertFalse(service.downloads.isQueued("have"))
        XCTAssertTrue(service.downloads.isQueued("need"))
    }

    // One entry per track the user skips past, pruned only by a completion event, grew without
    // limit across a long listening session.
    func test_cancelledDownloadMemory_isBounded() {
        let service = makeService()
        for i in 0...(TelegramService.maxCanceledDownloadMemory + 50) {
            service.noteCanceled("k\(i)")
        }
        XCTAssertLessThanOrEqual(service.canceledDownloadIds.count,
                                 TelegramService.maxCanceledDownloadMemory)
        XCTAssertTrue(service.canceledDownloadIds.contains("k\(TelegramService.maxCanceledDownloadMemory + 50)"),
                      "the most recent cancellations are the ones that still matter")
    }

    // Abandoning a track must actually stop the transfer. Cancelling our own polling task is not
    // enough — TDLib was told to download the file and keeps going on its own, so closing a song
    // or tapping a different one kept spending the user's bandwidth on tracks nobody wanted.
    func test_droppingATransientDownload_tellsTheBackendToStopFetching() async {
        let backend = MockTelegramBackend()
        let service = TelegramService(backend: backend)
        service.planPlaybackDownloads([track("a"), track("b")])

        service.cancelTransientDownload(key: "a")
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        let cancelled = await backend.cancelledDownloadIds
        XCTAssertTrue(cancelled.contains("a"), "the transfer must be stopped, not just untracked")
        let removed = await backend.removedLocalFileIds
        XCTAssertFalse(removed.contains("a"), "...but the bytes already fetched are kept")
    }

    // Closing the player (swiping the mini-player away) is the same promise: stop fetching for
    // playback, but leave anything the user explicitly asked for alone.
    func test_emptyPlaybackPlan_stopsPlaybackDownloadsButNotTheUsersOwn() {
        let service = makeService()
        service.download(track("wanted"))
        service.planPlaybackDownloads([track("a"), track("b")])

        service.planPlaybackDownloads([])

        XCTAssertFalse(service.downloads.isQueued("a"))
        XCTAssertFalse(service.downloads.isQueued("b"))
        XCTAssertTrue(service.downloads.isQueued("wanted"), "Download all keeps running")
    }

    // MARK: - A failure keeps the pipeline running

    func test_retryableFailure_keepsTheRowDownloadingAndRequeuesIt() {
        let service = makeService()
        let song = track("x")
        service.download(song)
        guard let entry = service.downloads.entry("x") else { return XCTFail("nothing queued") }

        service.handleDownloadFailure(song, entry: entry, error: TelegramError.transient("link dropped"))

        XCTAssertTrue(service.downloads.isQueued("x"), "a dropped link is retried, not abandoned")
        XCTAssertTrue(service.isDownloading(song), "and the row keeps showing progress, not a failure")
        XCTAssertNil(service.downloadError, "nothing to tell the user yet — it is still working")
        XCTAssertNil(service.lastError)
    }

    func test_permanentFailure_reportsOnceAndDropsOnlyThatTrack() {
        let service = makeService()
        let dead = track("dead"), fine = track("fine")
        service.download(dead)
        service.download(fine)
        guard let entry = service.downloads.entry("dead") else { return XCTFail("nothing queued") }

        service.handleDownloadFailure(dead, entry: entry, error: TelegramError.deleted("Song dead"))

        XCTAssertFalse(service.downloads.isQueued("dead"))
        XCTAssertNotNil(service.downloadError)
        XCTAssertNil(service.lastError, "a download failure must never raise the playback banner")
        XCTAssertTrue(service.downloads.isQueued("fine"), "the rest of the queue carries on")
    }

    func test_resumeDeferredDownloads_clearsBackoffsWhenTheLinkReturns() {
        let service = makeService()
        let song = track("x")
        service.download(song)
        guard let entry = service.downloads.entry("x") else { return XCTFail("nothing queued") }
        service.handleDownloadFailure(song, entry: entry, error: TelegramError.transient("offline"))

        service.resumeDeferredDownloads()
        XCTAssertEqual(service.downloads.entry("x")?.attempts ?? 0, 0,
                       "back online is a fresh start for parked downloads")
    }

    // MARK: - Downloads vs. cache

    // The bug this exists to prevent: the success path passed no `explicit:` at all, so it took
    // the default `true` and *every* playback prefetch landed in the Downloaded library. Nothing
    // was ever cached, nothing was ever evicted, and the storage split did nothing.
    func test_aTrackDownloadedByPlayback_isCachedNotDownloaded() {
        let service = makeService()
        service.markDownloaded(track("played"), explicit: false, bytes: 5_000_000)

        XCTAssertFalse(service.downloadedIds.contains("played"), "the user never asked to keep it")
        XCTAssertTrue(service.cachedIds.contains("played"))
        XCTAssertEqual(service.cachedAudioBytes, 5_000_000)
        XCTAssertTrue(service.isAvailableOffline(track("played")),
                      "but it is a real file, so it still plays with no network")
    }

    func test_aTrackTheUserDownloaded_isNotCache() {
        let service = makeService()
        service.markDownloaded(track("kept"), explicit: true, bytes: 5_000_000)

        XCTAssertTrue(service.downloadedIds.contains("kept"))
        XCTAssertFalse(service.cachedIds.contains("kept"))
        XCTAssertEqual(service.cachedAudioBytes, 0, "explicit downloads don't count against the budget")
    }

    // Tapping Download on something already cached moves it across rather than re-fetching it.
    func test_downloadingACachedTrack_promotesIt() {
        let service = makeService()
        service.markDownloaded(track("x"), explicit: false, bytes: 1_000_000)
        service.markDownloaded(track("x"), explicit: true, bytes: 1_000_000)

        XCTAssertTrue(service.downloadedIds.contains("x"))
        XCTAssertFalse(service.cachedIds.contains("x"))
        XCTAssertEqual(service.cachedAudioBytes, 0)
    }

    func test_keepEverythingIPlay_sendsPlayedTracksToDownloads() {
        let service = makeService()
        service.autoDownloadPlayed = true
        // Remove rather than set false: the setting is persisted, and writing an explicit `false`
        // here would leave every later test (in this run and the next) with it switched off.
        defer { UserDefaults.standard.removeObject(forKey: StorageKeys.autoDownload) }

        service.markDownloaded(track("played"), explicit: service.autoDownloadPlayed, bytes: 1_000)
        XCTAssertTrue(service.downloadedIds.contains("played"))
        XCTAssertFalse(service.cachedIds.contains("played"))
    }

    // The progress ring means "the download you asked for"; playback quietly filling its cache
    // must not make every track the user plays look like it is downloading.
    // The ring means "this file is being kept". With "Keep everything I play" **off**, a playback
    // download is cache the user never asked for, so no ring.
    func test_progressRing_hiddenForCacheFills() {
        let service = makeService()
        service.autoDownloadPlayed = false
        defer { UserDefaults.standard.removeObject(forKey: StorageKeys.autoDownload) }

        service.planPlaybackDownloads([track("playing")])
        service.downloadProgressByTrack["playing"] = 0.4
        XCTAssertNil(service.downloadFraction(for: track("playing")))

        service.download(track("wanted"))
        service.downloadProgressByTrack["wanted"] = 0.4
        XCTAssertEqual(service.downloadFraction(for: track("wanted")), 0.4)
    }

    // ...and with it **on**, every played track is headed for the Downloaded library, so the ring
    // has to fill. Without this the button sat empty for the whole transfer and then snapped to
    // "downloaded" — nothing happening, followed by magic.
    func test_progressRing_fillsForPlaybackWhenKeepEverythingIsOn() {
        let service = makeService()
        service.autoDownloadPlayed = true
        defer { UserDefaults.standard.removeObject(forKey: StorageKeys.autoDownload) }

        service.planPlaybackDownloads([track("playing")])
        service.downloadProgressByTrack["playing"] = 0.4

        XCTAssertEqual(service.downloadFraction(for: track("playing")), 0.4)
    }

    // The ring must not be bought by making playback transfers *look* user-owned: three behaviours
    // key off `explicitDownloadIds`, and this is the one that used to break.
    func test_keepEverythingOn_doesNotMakePlaybackDownloadsBulkStoppable() {
        let service = makeService()
        service.autoDownloadPlayed = true
        defer { UserDefaults.standard.removeObject(forKey: StorageKeys.autoDownload) }

        service.planPlaybackDownloads([track("playing")])
        XCTAssertFalse(service.isExplicitlyDownloading(track("playing")),
                       "the chat screen's Stop button must not count the playing track")

        service.stopDownloads([track("playing")])
        XCTAssertTrue(service.downloads.isQueued("playing"), "...nor cancel it")
    }

    // The other one: the player closing (an empty plan) still has to stop its own downloads.
    func test_keepEverythingOn_stillCancelsPlaybackDownloadsWhenThePlanEmpties() {
        let service = makeService()
        service.autoDownloadPlayed = true
        defer { UserDefaults.standard.removeObject(forKey: StorageKeys.autoDownload) }

        service.planPlaybackDownloads([track("a"), track("b")])
        service.planPlaybackDownloads([])

        XCTAssertFalse(service.downloads.isQueued("a"))
        XCTAssertFalse(service.downloads.isQueued("b"))
    }

    // Tapping the download button again takes the track back out — so the round trip has to leave
    // no trace in either half of the store, or the row would come back as downloaded/cached.
    func test_downloadThenRemove_leavesNothingBehind() async {
        let backend = MockTelegramBackend()
        let service = TelegramService(backend: backend)
        service.markDownloaded(track("x"), explicit: true, bytes: 4_000_000)
        XCTAssertTrue(service.isDownloaded(track("x")))

        service.removeDownload(track("x"))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(service.isDownloaded(track("x")))
        XCTAssertFalse(service.cachedIds.contains("x"), "removing must not demote it into the cache")
        XCTAssertFalse(service.isAvailableOffline(track("x")))
        XCTAssertEqual(service.cachedAudioBytes, 0)
        let removed = await backend.removedLocalFileIds
        XCTAssertTrue(removed.contains("x"), "the file itself has to go — that is the point")
    }

    // Mid-download, the same button cancels. That path deletes rather than merely stopping,
    // because the user is undoing the download, not skipping past the track.
    func test_removingAnInFlightDownload_cancelsAndDeletes() async {
        let backend = MockTelegramBackend()
        let service = TelegramService(backend: backend)
        service.download(track("x"))
        XCTAssertTrue(service.isDownloading(track("x")))

        service.removeDownload(track("x"))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(service.isDownloading(track("x")))
        XCTAssertFalse(service.downloads.isQueued("x"))
        let removed = await backend.removedLocalFileIds
        XCTAssertTrue(removed.contains("x"))
    }

    // MARK: - Clearing the cache must not break what is in use

    // Pressing Clear cache during a song must not delete the file of the song that is playing.
    // The protected set is refreshed at clear time precisely because the playing track stops being
    // tracked by the scheduler once its download completes — after which it looked like ordinary
    // cache.
    func test_clearCache_keepsTheTrackThatIsPlaying() async {
        let backend = MockTelegramBackend()
        let service = TelegramService(backend: backend)
        service.planPlaybackDownloads([track("playing"), track("next")])
        service.markDownloaded(track("playing"), explicit: false, bytes: 3_000_000)
        service.markDownloaded(track("stale"), explicit: false, bytes: 3_000_000)

        service.clearAudioCache()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(service.isAvailableOffline(track("playing")), "the song playing must survive")
        XCTAssertFalse(service.isAvailableOffline(track("stale")))
        let removed = await backend.removedLocalFileIds
        XCTAssertFalse(removed.contains("playing"))
        XCTAssertTrue(removed.contains("stale"))
    }

    func test_clearCache_keepsExplicitDownloads() async {
        let backend = MockTelegramBackend()
        let service = TelegramService(backend: backend)
        service.markDownloaded(track("kept"), explicit: true, bytes: 3_000_000)
        service.markDownloaded(track("cached"), explicit: false, bytes: 3_000_000)

        service.clearAudioCache()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(service.isDownloaded(track("kept")))
        let removed = await backend.removedLocalFileIds
        XCTAssertFalse(removed.contains("kept"), "Clear cache must not touch the user's downloads")
    }

    // A download the user is watching complete is not cache either, however long it has been going.
    func test_clearCache_doesNotInterruptADownloadInFlight() async {
        let backend = MockTelegramBackend()
        let service = TelegramService(backend: backend)
        service.download(track("downloading"))

        service.clearAudioCache()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(service.downloads.isQueued("downloading"))
        let removed = await backend.removedLocalFileIds
        XCTAssertFalse(removed.contains("downloading"))
    }

    // A cached file is a real file. Keying "can this play offline" off `isDownloaded` — which
    // answers the *different* question "did the user download this" — greyed out and skipped every
    // track the app had cached from playing it, which is precisely the case the cache exists for.
    func test_cachedTracksArePlayableOffline_evenThoughTheyAreNotDownloads() {
        let service = makeService()
        service.markDownloaded(track("cached"), explicit: false, bytes: 1_000_000)

        XCTAssertFalse(service.isDownloaded(track("cached")), "no checkmark — the user never asked")
        XCTAssertTrue(service.isAvailableOffline(track("cached")), "but it plays with no network")
    }

    func test_aTrackWithNoLocalFile_isNotAvailableOffline() {
        let service = makeService()
        XCTAssertFalse(service.isAvailableOffline(track("nothing")))
    }

    // Deleted-on-Telegram is about streaming, so a local copy of either kind overrides it.
    func test_aCachedCopyOutranksBeingDeletedOnTelegram() {
        let service = makeService()
        service.markTrackUnavailable(track("gone"))
        XCTAssertTrue(service.isUnavailableOnTelegram(track("gone")))

        service.markDownloaded(track("gone"), explicit: false, bytes: 1_000)
        XCTAssertFalse(service.isUnavailableOnTelegram(track("gone")),
                       "we still have the file, so it is not unavailable to the user")
    }

    // MARK: - Error surface separation

    // `lastError` is what the playback banner reads. A download dying must never touch it, or a
    // perfectly healthy player reports itself broken.
    func test_failedExplicitDownload_reportsOnDownloadErrorOnly() {
        let service = makeService()
        let song = track("x")
        service.downloadingIds.insert(song.remoteUniqueId)
        service.downloadProgressByTrack[song.remoteUniqueId] = 0.4

        service.finishFailedDownload(song, error: TelegramError.backend("Disk full."), wasExplicit: true)

        XCTAssertNil(service.lastError, "a download failure must not raise the playback banner")
        XCTAssertEqual(service.downloadError, "Couldn't download Song x. Disk full.")
        XCTAssertFalse(service.downloadingIds.contains(song.remoteUniqueId))
        XCTAssertNil(service.downloadFraction(for: song), "the progress ring must not keep spinning")
    }

    // Prefetches are the player's own idea; telling the user one failed is noise, not information.
    func test_failedPrefetch_isSilent() {
        let service = makeService()
        let song = track("y")
        service.downloadingIds.insert(song.remoteUniqueId)

        service.finishFailedDownload(song, error: TelegramError.transient("dropped"), wasExplicit: false)

        XCTAssertNil(service.lastError)
        XCTAssertNil(service.downloadError, "an unrequested prefetch failing is not the user's problem")
        XCTAssertFalse(service.downloadingIds.contains(song.remoteUniqueId))
    }

    func test_failedDownload_clearsExplicitFlagSoARetryCanBeRequested() {
        let service = makeService()
        let song = track("z")
        service.explicitDownloadIds.insert(song.remoteUniqueId)
        service.downloadingIds.insert(song.remoteUniqueId)

        service.finishFailedDownload(song, error: TelegramError.backend("nope"), wasExplicit: true)

        XCTAssertFalse(service.explicitDownloadIds.contains(song.remoteUniqueId))
        XCTAssertFalse(service.isDownloading(song), "the row must fall back to a tappable state")
    }
}

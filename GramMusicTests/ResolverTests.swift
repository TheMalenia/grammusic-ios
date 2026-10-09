import XCTest
@testable import GramMusic

/// The six tests the `Resolver` interface was reshaped to make possible — each exercises one tier
/// of the spine through the `ArtworkStore` seam, with no Telegram, no filesystem, no network.
/// The producer is a counting closure, so "how many times did the source run" is the assertion.
final class ResolverTests: XCTestCase {

    /// Counts how often a producer ran, and what it should yield.
    private actor Source {
        private(set) var calls = 0
        private let result: Data?
        init(returning result: Data?) { self.result = result }
        func produce() -> Data? { calls += 1; return result }
    }

    // 1. Produce once, then serve from the memory tier.
    func test_producesOnce_thenServesFromMemory() async {
        let source = Source(returning: Data([1]))
        let r = Resolver<Data>.data(store: nil, tracksMisses: true)

        let first = await r.value(for: "k") { await source.produce() }
        let second = await r.value(for: "k") { await source.produce() }

        XCTAssertEqual(first, Data([1]))
        XCTAssertEqual(second, Data([1]))
        let calls = await source.calls
        XCTAssertEqual(calls, 1, "second lookup must hit memory, not the producer")
    }

    // 2. A disk-tier hit is returned (and promoted to memory) without producing.
    func test_diskHit_servedWithoutProducing() async {
        let store = InMemoryArtworkStore()
        await store.store(Data([9]), for: "k")
        let source = Source(returning: Data([1]))
        let r = Resolver<Data>.data(store: store, tracksMisses: true)

        let value = await r.value(for: "k") { await source.produce() }

        XCTAssertEqual(value, Data([9]), "the disk tier wins over the producer")
        let calls = await source.calls
        XCTAssertEqual(calls, 0)
    }

    // 3. Produce writes back to both tiers (memory + the store).
    func test_produce_writesBackToDisk() async {
        let store = InMemoryArtworkStore()
        let source = Source(returning: Data([7]))
        let r = Resolver<Data>.data(store: store, tracksMisses: true)

        _ = await r.value(for: "k") { await source.produce() }

        let onDisk = await store.data(for: "k")
        XCTAssertEqual(onDisk, Data([7]), "a produced value must persist to the store")
    }

    // 4. When tracking misses, a nil producer isn't retried within the session.
    func test_miss_notRetried_whenTracking() async {
        let source = Source(returning: nil)
        let r = Resolver<Data>.data(store: nil, tracksMisses: true)

        let first = await r.value(for: "k") { await source.produce() }
        let second = await r.value(for: "k") { await source.produce() }

        XCTAssertNil(first)
        XCTAssertNil(second)
        let calls = await source.calls
        XCTAssertEqual(calls, 1, "a recorded miss must short-circuit the second lookup")
    }

    // 4b. Without miss-tracking, a nil producer is retried each lookup (provisional-cover policy).
    func test_miss_retried_whenNotTracking() async {
        let source = Source(returning: nil)
        let r = Resolver<Data>.data(store: nil, tracksMisses: false)

        _ = await r.value(for: "k") { await source.produce() }
        _ = await r.value(for: "k") { await source.produce() }

        let calls = await source.calls
        XCTAssertEqual(calls, 2)
    }

    // 4c. A *thrown* failure (network down / cancelled) is NOT a miss — the next lookup retries
    //     and can succeed. This is the fix for "cover only appears after relaunch".
    func test_thrownError_isNotAMiss_andRetries() async {
        struct Boom: Error {}
        let attempts = Counter()
        let r = Resolver<Data>.data(store: nil, tracksMisses: true)

        // `@Sendable`: it is captured by the resolver's producer closure, which is Sendable.
        @Sendable func produce() async throws -> Data? {
            let n = await attempts.next()
            if n == 1 { throw Boom() }   // first attempt fails transiently
            return Data([UInt8(n)])
        }

        let first = await r.value(for: "k") { try await produce() }
        let second = await r.value(for: "k") { try await produce() }

        XCTAssertNil(first, "a thrown error yields nil to the caller")
        XCTAssertEqual(second, Data([2]), "the retry re-runs the producer instead of caching a miss")
    }

    // 5. Concurrent lookups for one key coalesce onto a single producer run.
    func test_coalescesConcurrentLookups() async {
        let source = SlowSource()
        let r = Resolver<Data>.data(store: nil, tracksMisses: true)

        await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<10 {
                group.addTask { await r.value(for: "k") { await source.produce() } }
            }
            for await _ in group {}
        }

        let calls = await source.calls
        XCTAssertEqual(calls, 1, "ten concurrent callers must share one production")
    }

    // 6. clear() wipes every tier.
    func test_clear_wipesMemoryAndDisk() async {
        let store = InMemoryArtworkStore()
        let r = Resolver<Data>.data(store: store, tracksMisses: true)
        _ = await r.value(for: "k") { Data([1]) }

        await r.clear()

        let afterMemory = await r.cached(for: "k")
        XCTAssertNil(afterMemory)
        let afterDisk = await store.data(for: "k")
        XCTAssertNil(afterDisk)
    }

    // Bonus: invalidate drops one key from both tiers (markDownloaded's provisional-cover reset).
    func test_invalidate_dropsOneKey() async {
        let store = InMemoryArtworkStore()
        let r = Resolver<Data>.data(store: store, tracksMisses: true)
        _ = await r.value(for: "k") { Data([1]) }

        await r.invalidate("k")

        let cached = await r.cached(for: "k")
        XCTAssertNil(cached)
        let onDisk = await store.data(for: "k")
        XCTAssertNil(onDisk)
    }

    // Memory budget: once over `memoryLimit` the coldest entries are evicted from the memory tier,
    // but stay on disk — so an eviction costs a disk read, never a re-produce.
    func test_memoryBudget_evictsColdestButKeepsDisk() async {
        let store = InMemoryArtworkStore()
        // Room for two 100-byte entries, not three.
        let r = Resolver<Data>.data(store: store, tracksMisses: true, memoryLimit: 250)
        let blob = Data(repeating: 0xAB, count: 100)

        _ = await r.value(for: "a") { blob }
        _ = await r.value(for: "b") { blob }
        // Touch "a" so "b" becomes the coldest entry.
        _ = await r.cached(for: "a")
        _ = await r.value(for: "c") { blob }

        // "b" is gone from memory but still on disk.
        let evictedOnDisk = await store.data(for: "b")
        XCTAssertNotNil(evictedOnDisk)

        // It re-serves from disk without the producer running again.
        let produced = Counter()
        let revived = await r.value(for: "b") { _ = await produced.next(); return blob }
        XCTAssertEqual(revived, blob)
        let produceCalls = await produced.count
        XCTAssertEqual(produceCalls, 0, "evicted entry should come back from disk, not be re-produced")
    }

    // A miss recorded before eviction is still a miss afterwards (eviction is memory-only).
    func test_memoryBudget_doesNotResurrectMisses() async {
        let r = Resolver<Data>.data(store: InMemoryArtworkStore(), tracksMisses: true, memoryLimit: 250)
        _ = await r.value(for: "gone") { nil }

        let calls = Counter()
        _ = await r.value(for: "gone") { _ = await calls.next(); return nil }
        let callCount = await calls.count
        XCTAssertEqual(callCount, 0)
    }

    // 7. ArtworkDiskCache stores data on disk, reports usage, and clears.
    func test_artworkDiskCache_storeAndClear() async {
        let cache = ArtworkDiskCache.photos
        await cache.store(Data([1, 2, 3, 4, 5]), for: "test-photo-key")

        let data = await cache.data(for: "test-photo-key")
        XCTAssertEqual(data, Data([1, 2, 3, 4, 5]))

        let usage = await cache.diskUsage()
        XCTAssertGreaterThan(usage, 0)

        await cache.remove("test-photo-key")
        let afterRemove = await cache.data(for: "test-photo-key")
        XCTAssertNil(afterRemove)
    }

    // 8. PlayerEngine queue consistency: adding tracks during shuffle maintains unshuffled order.
    @MainActor
    func test_playerEngine_queueShuffleAddAndUnshuffle() async {
        let t1 = AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: "t1", title: "Song 1", performer: "Artist", duration: 100)
        let t2 = AudioTrack(chatId: 1, messageId: 2, fileId: 2, remoteUniqueId: "t2", title: "Song 2", performer: "Artist", duration: 100)
        let t3 = AudioTrack(chatId: 1, messageId: 3, fileId: 3, remoteUniqueId: "t3", title: "Song 3", performer: "Artist", duration: 100)
        let tManual = AudioTrack(chatId: 1, messageId: 4, fileId: 4, remoteUniqueId: "tManual", title: "Manual", performer: "Artist", duration: 100)

        let engine = PlayerEngine(fileProvider: { _ in URL(fileURLWithPath: "/tmp/fake.mp3") })
        engine.play(tracks: [t1, t2, t3], startAt: 0, context: "Test")
        engine.isShuffle = true

        // Add manual track while shuffled
        engine.addToQueue(tManual)
        XCTAssertTrue(engine.queue.contains(where: { $0.remoteUniqueId == "tManual" }))

        // Unshuffle
        engine.isShuffle = false
        XCTAssertTrue(engine.queue.contains(where: { $0.remoteUniqueId == "tManual" }))
        XCTAssertTrue(engine.unshuffledEntries.contains(where: { $0.track.remoteUniqueId == "tManual" }))
    }

    // 9. Equalizer presets provide valid 5-band gain arrays and Biquad coefficients.
    func test_equalizerPresets_andBiquadCoefficients() {
        for preset in EqualizerPreset.allCases {
            XCTAssertEqual(preset.gains.count, 5, "Preset \(preset.rawValue) must have 5 band gains")
        }

        let lowShelf = BiquadCoefficients.lowShelf(frequency: 60, sampleRate: 44100, gainDB: 6.0)
        XCTAssertNotEqual(lowShelf.b0, 1.0)

        let peaking = BiquadCoefficients.peaking(frequency: 1000, sampleRate: 44100, gainDB: 3.0)
        XCTAssertNotEqual(peaking.b0, 1.0)

        let highShelf = BiquadCoefficients.highShelf(frequency: 12000, sampleRate: 44100, gainDB: -3.0)
        XCTAssertNotEqual(highShelf.b0, 1.0)
    }

    // 10. PlayerEngine equalizer state and presets.
    @MainActor
    func test_playerEngine_equalizerControls() {
        let engine = PlayerEngine(fileProvider: { _ in URL(fileURLWithPath: "/tmp/fake.mp3") })
        engine.setEqualizerEnabled(true)
        XCTAssertTrue(engine.isEqualizerEnabled)

        engine.setEqualizerPreset(.bassBooster)
        XCTAssertEqual(engine.equalizerPreset, .bassBooster)
        XCTAssertEqual(engine.equalizerGains, EqualizerPreset.bassBooster.gains)

        engine.setEqualizerGain(3.5, at: 2)
        XCTAssertEqual(engine.equalizerPreset, .custom)
        XCTAssertEqual(engine.equalizerGains[2], 3.5)

        engine.resetEqualizer()
        XCTAssertEqual(engine.equalizerPreset, .flat)
        XCTAssertEqual(engine.equalizerGains, EqualizerPreset.flat.gains)
    }

    // 11. PlayerEngine preloads upcoming artwork on shuffle and unshuffle.
    @MainActor
    func test_playerEngine_preloadUpcomingArtwork_onShuffleAndUnshuffle() async {
        let t1 = AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: "t1", title: "Song 1", performer: "Artist 1", duration: 100)
        let t2 = AudioTrack(chatId: 1, messageId: 2, fileId: 2, remoteUniqueId: "t2", title: "Song 2", performer: "Artist 2", duration: 100)
        let t3 = AudioTrack(chatId: 1, messageId: 3, fileId: 3, remoteUniqueId: "t3", title: "Song 3", performer: "Artist 3", duration: 100)

        var requestedArtworkIds: Set<String> = []
        let dummyArtData = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let engine = PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/tmp/fake.mp3") },
            artworkProvider: { track in
                requestedArtworkIds.insert(track.remoteUniqueId)
                return dummyArtData
            }
        )

        engine.play(tracks: [t1, t2, t3], startAt: 0, context: "Test")
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(requestedArtworkIds.contains("t1"))
        XCTAssertTrue(requestedArtworkIds.contains("t2"))

        // Toggle shuffle
        requestedArtworkIds.removeAll()
        engine.isShuffle = true
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(requestedArtworkIds.isEmpty)

        // Toggle unshuffle
        requestedArtworkIds.removeAll()
        engine.isShuffle = false
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(requestedArtworkIds.isEmpty)
    }

    // 12. TelegramService preloadInitialMusicCovers populates preloadedCoversCount with mock backend.
    @MainActor
    func test_telegramService_preloadInitialMusicCovers() async {
        let service = TelegramService(backend: MockTelegramBackend())
        XCTAssertFalse(service.isPreloadingCovers)
        XCTAssertEqual(service.preloadedCoversCount, 0)

        await service.refreshChats()
        await service.preloadInitialMusicCovers()

        XCTAssertFalse(service.isPreloadingCovers)
        XCTAssertGreaterThan(service.preloadedCoversCount, 0)
    }

    // Signed out from another device: Telegram drops us back to the phone screen without the user
    // asking. That must wipe this account's local data, end the playback session, and leave a
    // notice explaining why — otherwise the next person to sign in inherits the previous account's
    // library and audio keeps playing over the login screen.
    @MainActor
    func test_remoteSignOut_wipesLocalDataAndExplainsItself() async {
        let service = TelegramService(backend: MockTelegramBackend())
        var sessionEndedCount = 0
        service.onSessionEnded = { sessionEndedCount += 1 }
        service.bootstrap()
        // Wait for the backend's own start-up transition to land first. Driving the login before
        // it does lets a late `.waitingForPhoneNumber` arrive *after* `.ready` and read as a
        // spurious remote sign-out — a flake in the test, not the code.
        await waitUntil { service.authState == .waitingForPhoneNumber }

        // Sign in.
        await service.setPhoneNumber("+15550100")
        await service.checkCode("11111")
        await waitUntil { service.authState == .ready }
        XCTAssertEqual(service.authState, .ready)

        // Accumulate some account-scoped local state.
        let track = AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: "t1",
                               title: "Song", performer: "Artist", duration: 100)
        service.recordRecent(track)
        service.toggleFollow(artist: "Artist")
        XCTAssertFalse(service.recentlyPlayed.isEmpty)
        XCTAssertFalse(service.followedArtists.isEmpty)

        // The session ends without a user-initiated logout (remote revoke).
        await service.resetAuth()
        await waitUntil { service.sessionExpiredNotice != nil }

        XCTAssertNotNil(service.sessionExpiredNotice, "user must be told why they were signed out")
        XCTAssertTrue(service.recentlyPlayed.isEmpty, "recently played must not survive a sign-out")
        XCTAssertTrue(service.followedArtists.isEmpty, "followed artists must not survive a sign-out")
        XCTAssertTrue(service.chats.isEmpty)
        XCTAssertEqual(sessionEndedCount, 1, "playback session should be ended exactly once")
    }

    /// The App Review demo account must survive a relaunch. It runs on the mock backend, which
    /// used to always cold-start at the phone screen — so quitting and reopening the app signed
    /// the reviewer straight back out.
    @MainActor
    func test_demoSession_survivesRelaunch() async {
        UserDefaults.standard.removeObject(forKey: "n_mockSignedIn")
        UserDefaults.standard.removeObject(forKey: AppConfig.demoModeKey)
        defer {
            UserDefaults.standard.removeObject(forKey: "n_mockSignedIn")
            // Demo mode is a persisted, process-wide flag — leaking it into the next test made
            // that test's service think it was a demo session.
            UserDefaults.standard.removeObject(forKey: AppConfig.demoModeKey)
        }

        let first = TelegramService(backend: MockTelegramBackend(persistsSession: true))
        first.bootstrap()
        await waitUntil { first.authState == .waitingForPhoneNumber }
        await first.setPhoneNumber(AppConfig.demoPhoneNumber)
        await first.checkCode("11111")
        await waitUntil { first.authState == .ready }
        XCTAssertEqual(first.authState, .ready)

        // Relaunch: a brand new service over a brand new backend, as `makeDefault()` builds it.
        let relaunched = TelegramService(backend: MockTelegramBackend(persistsSession: true))
        relaunched.bootstrap()
        await waitUntil { relaunched.authState == .ready }
        XCTAssertEqual(relaunched.authState, .ready,
                       "a demo session must not be dropped back to the login screen on relaunch")
        XCTAssertNil(relaunched.sessionExpiredNotice,
                     "resuming a demo session is not a sign-out and must not be announced as one")
    }

    /// The relaunch path the old test skipped. `test_demoSession_survivesRelaunch` builds
    /// `MockTelegramBackend(persistsSession: true)` by hand, which is exactly what the two places
    /// the bug lived — `enterDemoMode()` and the launch-time backend choice — are responsible for
    /// producing. Here the demo session is started the way the *user* starts it (by entering the
    /// demo number), and the relaunch reproduces the launch-time decision from persisted state
    /// only. Before the fix, `n_mockSignedIn` was never written and the relaunch bounced to login.
    @MainActor
    func test_demoLogin_throughPhoneNumber_survivesRelaunch() async {
        for key in ["n_mockSignedIn", AppConfig.demoModeKey, "n_isLoggedIn"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        defer {
            for key in ["n_mockSignedIn", AppConfig.demoModeKey, "n_isLoggedIn"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // First run: a plain mock backend, exactly as mock development mode starts.
        let first = TelegramService(backend: MockTelegramBackend())
        first.bootstrap()
        await waitUntil { first.authState == .waitingForPhoneNumber }
        await first.setPhoneNumber(AppConfig.demoPhoneNumber)
        await first.checkCode("11111")
        await waitUntil { first.authState == .ready }
        XCTAssertEqual(first.authState, .ready, "the demo number must sign in")
        XCTAssertTrue(AppConfig.isDemoModeActive,
                      "entering the demo number must persist demo mode, or relaunch can't restore it")

        // Relaunch: rebuild the backend from persisted state the way makeDefault() does.
        let signedIn = AppConfig.isDemoModeActive && UserDefaults.standard.bool(forKey: "n_isLoggedIn")
        let relaunched = TelegramService(
            backend: MockTelegramBackend(persistsSession: AppConfig.isDemoModeActive,
                                         startsSignedIn: signedIn)
        )
        relaunched.bootstrap()
        await waitUntil { relaunched.authState == .ready }
        XCTAssertEqual(relaunched.authState, .ready,
                       "a demo session must survive relaunch, not drop back to the login screen")
        XCTAssertNil(relaunched.sessionExpiredNotice,
                     "resuming is not a sign-out and must not be announced as one")
    }

    /// `.closed` is a recoverable internal TDLib event — it recreates the client right after.
    /// Treating it as a remote sign-out wiped playlists, downloads and history on a reconnect.
    @MainActor
    func test_closedState_isNotTreatedAsRemoteSignOut() async {
        for key in ["n_mockSignedIn", AppConfig.demoModeKey, "n_isLoggedIn"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        defer {
            for key in ["n_mockSignedIn", AppConfig.demoModeKey, "n_isLoggedIn"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let backend = MockTelegramBackend()
        let service = TelegramService(backend: backend)
        var sessionEndedCount = 0
        service.onSessionEnded = { sessionEndedCount += 1 }
        service.bootstrap()
        await waitUntil { service.authState == .waitingForPhoneNumber }
        await service.setPhoneNumber("+1 202 555 0111")
        await service.checkCode("11111")
        await waitUntil { service.authState == .ready }

        service.toggleFollow(artist: "Aphex Twin")
        await backend.emitClosedForTesting()
        await waitUntil { service.authState == .closed }

        XCTAssertNil(service.sessionExpiredNotice,
                     "a transient TDLib close is not a sign-out and must not be announced as one")
        XCTAssertEqual(sessionEndedCount, 0, "a transient close must not end the playback session")
        XCTAssertEqual(service.followedArtists, ["Aphex Twin"],
                       "a transient close must not wipe the account's local data")
    }

    /// Plain mock *development* mode is deliberately not sticky — the login flow stays exercisable.
    @MainActor
    func test_mockDevelopmentSession_isNotSticky() async {
        UserDefaults.standard.set(true, forKey: "n_mockSignedIn")
        defer { UserDefaults.standard.removeObject(forKey: "n_mockSignedIn") }

        let service = TelegramService(backend: MockTelegramBackend())
        service.bootstrap()
        await waitUntil { service.authState == .waitingForPhoneNumber }
        XCTAssertEqual(service.authState, .waitingForPhoneNumber)
    }

    /// Poll until `condition` holds, up to `timeout`. The auth/connection mirrors are driven by
    /// AsyncStreams, so state lands a few hops after the call that triggered it.
    @MainActor
    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Counts attempts and returns the running count, so a test can vary behaviour per attempt.
    private actor Counter {
        private var n = 0
        /// How many times `next()` has been called — lets a test assert a producer never ran.
        var count: Int { n }
        func next() -> Int { n += 1; return n }
    }

    /// A producer that sleeps so concurrent callers overlap, proving coalescing.
    private actor SlowSource {
        private(set) var calls = 0
        func produce() async -> Data? {
            calls += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
            return Data([1])
        }
    }
}

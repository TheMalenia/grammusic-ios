import Foundation

/// The disk seam behind a `Resolver`'s persistent tier. `ArtworkDiskCache` is the real adapter
/// (writes to `Caches/Artwork/<namespace>`); tests substitute an in-memory adapter so a
/// `Resolver` can be exercised without touching the filesystem. Bytes only — the resolver owns
/// the value↔Data codec and every caching *decision*; a store never decides whether to re-query.
protocol ArtworkStore: Sendable {
    func data(for key: String) async -> Data?
    func store(_ data: Data, for key: String) async
    func remove(_ key: String) async
    func clear() async
}

/// Resolves a key into a cached **track attribute** (cover, lyrics, photo) through one fixed
/// spine — memory tier → optional disk tier → produce-from-source → cache back → miss-track →
/// in-flight coalesce. One instance per attribute kind; the source is supplied per call (so it
/// can close over the `AudioTrack`/name the key was derived from), while the tiering policy lives
/// here. Replaces the hand-rolled cache dance that used to be copied across `TelegramService`.
///
/// An `actor` so memory bookkeeping is race-free and disk I/O stays off the main actor.
actor Resolver<Value: Sendable> {

    private var memory: [String: Value] = [:]
    /// Keys whose source produced nothing this session — not retried while `tracksMisses`.
    private var misses: Set<String> = []
    /// Live lookups, so concurrent callers for the same key share one `produce` instead of each
    /// firing a duplicate embedded-read / network request.
    private var inFlight: [String: Task<Value?, Never>] = [:]

    // MARK: Memory budget
    //
    // The memory tier is an *cache*, not a registry: without eviction it grew for the whole
    // session, and for the cover resolvers each entry is a ~1000px JPEG. Browsing a large library
    // could therefore accumulate hundreds of MB of resident images until the OS jetsammed the app.
    // Entries are evicted least-recently-used once `memoryLimit` is exceeded; the disk tier still
    // has them, so an eviction costs one disk read, never a re-fetch from the network.

    /// Budget in `cost` units (bytes for the `Data` resolvers).
    private let memoryLimit: Int
    private let cost: @Sendable (Value) -> Int
    private var costs: [String: Int] = [:]
    private var totalCost = 0
    /// Monotonic access stamps backing the LRU order.
    private var lastUsed: [String: UInt64] = [:]
    private var clock: UInt64 = 0

    private let store: ArtworkStore?
    private let tracksMisses: Bool
    private let decode: @Sendable (Data) -> Value?
    private let encode: @Sendable (Value) -> Data?

    init(store: ArtworkStore?,
         tracksMisses: Bool,
         memoryLimit: Int = 32 * 1024 * 1024,
         cost: @escaping @Sendable (Value) -> Int = { _ in 1 },
         decode: @escaping @Sendable (Data) -> Value?,
         encode: @escaping @Sendable (Value) -> Data?) {
        self.store = store
        self.tracksMisses = tracksMisses
        self.memoryLimit = memoryLimit
        self.cost = cost
        self.decode = decode
        self.encode = encode
    }

    /// Record an access for LRU ordering.
    private func touch(_ key: String) {
        clock &+= 1
        lastUsed[key] = clock
    }

    private func insertIntoMemory(_ value: Value, for key: String) {
        if let old = costs[key] { totalCost -= old }
        let c = max(1, cost(value))
        memory[key] = value
        costs[key] = c
        totalCost += c
        touch(key)
        evictIfNeeded()
    }

    private func dropFromMemory(_ key: String) {
        if let old = costs.removeValue(forKey: key) { totalCost -= old }
        memory[key] = nil
        lastUsed[key] = nil
    }

    private func evictIfNeeded() {
        guard totalCost > memoryLimit else { return }
        // Evict coldest-first until back under budget. Sorting is O(n log n) but only runs when
        // the budget is actually exceeded, not on every insert.
        for key in lastUsed.sorted(by: { $0.value < $1.value }).map(\.key) {
            guard totalCost > memoryLimit else { break }
            dropFromMemory(key)
        }
    }

    /// The cached value if one already exists (memory, then disk — promoting a disk hit into
    /// memory). Never produces. Used when a *different* source must run between the disk tier and
    /// the resolver's own producer (the cover resolver's every-lookup embedded-art retry).
    func cached(for key: String) async -> Value? {
        if let value = memory[key] { touch(key); return value }
        guard let store, let data = await store.data(for: key), let value = decode(data) else { return nil }
        insertIntoMemory(value, for: key)
        return value
    }

    /// The full spine: cached value, else `produce` once (coalesced), caching the result and
    /// recording a miss when it yields nothing. `produce` is supplied per call so it can close
    /// over the track/name the key came from.
    ///
    /// `produce` distinguishes two kinds of "no value": returning `nil` is a *genuine* miss (the
    /// source has nothing — don't ask again this session when `tracksMisses`), while *throwing* is
    /// a transient failure (network down, request cancelled — neither cached nor recorded, so the
    /// next lookup retries). Non-throwing closures still satisfy the signature.
    func value(for key: String, produce: @escaping @Sendable () async throws -> Value?) async -> Value? {
        if let value = memory[key] { touch(key); return value }
        if let task = inFlight[key] { return await task.value }
        let task = Task<Value?, Never> { await self.resolve(key, produce: produce) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func resolve(_ key: String, produce: @Sendable () async throws -> Value?) async -> Value? {
        // Check recorded misses *first*: `cached` would otherwise hit the filesystem for a key we
        // already know has no entry — a failed read per row, per appearance.
        if tracksMisses, misses.contains(key) { return nil }
        if let value = await cached(for: key) { return value }
        do {
            guard let produced = try await produce() else {
                if tracksMisses { misses.insert(key) }   // the source genuinely has nothing
                return nil
            }
            // A logout between `produce` starting and finishing must not resurrect the previous
            // account's artwork/lyrics — `clear()` cancels us, so don't write after that.
            if Task.isCancelled { return produced }
            await write(produced, for: key)
            return produced
        } catch {
            return nil   // transient failure — don't cache, don't record a miss; retry next time
        }
    }

    /// Force a value into the cache (memory + disk), clearing any recorded miss. Used to promote a
    /// freshly-found final cover ahead of its producer.
    func adopt(_ value: Value, for key: String) async {
        await write(value, for: key)
    }

    private func write(_ value: Value, for key: String) async {
        insertIntoMemory(value, for: key)
        misses.remove(key)
        if let store, let data = encode(value) { await store.store(data, for: key) }
    }

    /// Drop one entry from every tier (e.g. a provisional cover once its file lands, so the next
    /// lookup re-resolves the embedded full-res one).
    func invalidate(_ key: String) async {
        dropFromMemory(key)
        misses.remove(key)
        await store?.remove(key)
    }

    /// Wipe every tier (log out).
    func clear() async {
        memory.removeAll()
        costs.removeAll()
        lastUsed.removeAll()
        totalCost = 0
        misses.removeAll()
        // Cancel, don't just forget: a dropped-but-running task still calls `write`, which puts
        // the value back in memory *and* on disk after the wipe.
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        await store?.clear()
    }
}

extension Resolver where Value == Data {
    /// A resolver whose value *is* `Data` (covers, photos) — identity codec, no boilerplate.
    /// Budgeted by actual byte size, since these are full-resolution JPEGs.
    static func data(store: ArtworkStore?,
                     tracksMisses: Bool,
                     memoryLimit: Int = 32 * 1024 * 1024) -> Resolver<Data> {
        Resolver(store: store, tracksMisses: tracksMisses,
                 memoryLimit: memoryLimit, cost: { $0.count },
                 decode: { $0 }, encode: { $0 })
    }
}

extension Resolver where Value: Codable {
    /// A resolver over a `Codable` value (lyrics) — JSON to/from the disk tier.
    /// Lyrics are small, so this budget is a plain entry count.
    static func json(_ type: Value.Type,
                     store: ArtworkStore?,
                     tracksMisses: Bool,
                     memoryLimit: Int = 500) -> Resolver<Value> {
        Resolver(store: store, tracksMisses: tracksMisses,
                 memoryLimit: memoryLimit,
                 decode: { try? JSONDecoder().decode(Value.self, from: $0) },
                 encode: { try? JSONEncoder().encode($0) })
    }
}

/// In-memory `ArtworkStore` — the second adapter that makes the seam real, so `Resolver` tests
/// run without the filesystem.
actor InMemoryArtworkStore: ArtworkStore {
    private var storage: [String: Data] = [:]
    func data(for key: String) -> Data? { storage[key] }
    func store(_ data: Data, for key: String) { storage[key] = data }
    func remove(_ key: String) { storage[key] = nil }
    func clear() { storage.removeAll() }
}

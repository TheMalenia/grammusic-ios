import Foundation

/// Separates API results from file fallback: previously cached embedded lyrics must not prevent
/// an API lookup, and lyrics found offline must still be upgradeable when back online.
actor LyricsResolver {
    private let apiCache: Resolver<Lyrics>
    private let fileCache: Resolver<Lyrics>

    init(store: ArtworkStore?) {
        apiCache = .json(Lyrics.self, store: store, tracksMisses: true)
        // File lyrics can appear after an audio download, so a file miss is always retryable.
        fileCache = .json(Lyrics.self, store: store, tracksMisses: false)
    }

    func lyrics(for key: String, offline: Bool,
                api: @escaping @Sendable () async -> String?,
                embedded: @escaping @Sendable () async -> String?) async -> Lyrics? {
        let apiKey = "lrclib:\(key)"
        if let cached = await apiCache.cached(for: apiKey) { return cached }

        // Preserve the old disk cache, including API results stored under a bare track ID.
        let existing = await fileCache.cached(for: key)
        if let existing, existing.source == .lrclib {
            await apiCache.adopt(existing, for: apiKey)
            return existing
        }

        if !offline, let result = await apiCache.value(for: apiKey, produce: {
            guard let raw = await api() else { return nil }
            return Lyrics.parse(raw, source: .lrclib)
        }) {
            return result
        }

        if let existing { return existing }
        return await fileCache.value(for: key) {
            guard let raw = await embedded() else { return nil }
            return Lyrics.parse(raw, source: .embedded)
        }
    }

    func clear() async {
        await apiCache.clear()
        await fileCache.clear()
    }
}

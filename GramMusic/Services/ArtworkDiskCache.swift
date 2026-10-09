import Foundation
import CryptoKit

/// Disk-backed image cache so resolved covers/photos survive relaunches. The in-memory
/// caches in `TelegramService` are lost on every launch, which forced a fresh network
/// fetch (iTunes) for every cover on each app open — the slow part the user sees. This
/// persists those results under Caches/Artwork/<namespace> and is read into memory lazily.
///
/// An `actor` so its file I/O runs off the main actor. Keys are hashed (SHA-256) into safe
/// filenames since `remoteUniqueId` may contain path-unsafe characters.
///
/// This is the *disk adapter* for the `ArtworkStore` seam — a `Resolver` talks to it through
/// that protocol, so tests can swap in `InMemoryArtworkStore` instead.
actor ArtworkDiskCache: ArtworkStore {
    // Namespaces are versioned: bumping the suffix abandons entries written by earlier
    // (buggy) cover logic instead of trusting a possibly-poisoned low-res cover.
    /// Final covers (iTunes or embedded full-res) — these never improve, safe to trust forever.
    static let covers = ArtworkDiskCache(namespace: "covers-v2")
    /// Provisional covers (Telegram's small thumbnail) — shown instantly but upgradeable.
    static let thumbs = ArtworkDiskCache(namespace: "thumbs-v2")
    static let photos = ArtworkDiskCache(namespace: "photos-v2")
    /// Artist portraits — real iTunes artist photos only (final, never improve). v3 abandons v2's
    /// frozen track-derived covers, which couldn't upgrade when the underlying track cover did.
    static let artists = ArtworkDiskCache(namespace: "artists-v3")
    /// Resolved lyrics (JSON-encoded `Lyrics`) — a generic Data cache reused for text.
    static let lyrics = ArtworkDiskCache(namespace: "lyrics-v1")

    private let dir: URL

    private init(namespace: String) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Artwork/\(namespace)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name)
    }

    func data(for key: String) -> Data? {
        try? Data(contentsOf: fileURL(for: key))
    }

    func store(_ data: Data, for key: String) {
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    /// Drop a single entry (e.g. when a track finishes downloading and its low-res cover
    /// should be re-resolved to the embedded full-res one).
    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    /// Wipe everything in this namespace (e.g. on log out).
    func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Calculate byte size of this namespace's directory.
    func diskUsage() -> Int64 {
        Self.directorySize(at: dir)
    }

    /// Calculate total bytes across all Artwork namespaces in Caches/Artwork.
    static func totalArtworkCacheBytes() -> Int64 {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let artworkDir = base.appendingPathComponent("Artwork", isDirectory: true)
        return directorySize(at: artworkDir)
    }

    /// Recursively calculate the size of any directory.
    static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  resourceValues.isDirectory != true,
                  let size = resourceValues.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}

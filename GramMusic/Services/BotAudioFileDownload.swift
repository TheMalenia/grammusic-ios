import Foundation

/// TDLib delegates URL-backed inline audio to the client through its #url# file-generation
/// updates. Downloads into TDLib's destination so caching, playlists and offline playback all
/// use the existing file pipeline. Never interpreted as a message-send operation.
enum BotAudioFileDownload {
    static func download(from url: URL, to destination: URL, session: URLSession = .shared) async throws {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw TelegramError.backend("The bot returned an invalid audio URL.")
        }
        let (temporary, response) = try await session.download(for: URLRequest(url: url, timeoutInterval: 40))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try install(temporaryFile: temporary, response: response, to: destination)
    }

    /// Separate from transport so response validation and file installation can be tested offline.
    static func install(temporaryFile: URL, response: URLResponse, to destination: URL) throws {
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TelegramError.backend("The bot's audio link is unavailable.")
        }
        guard let format = AudioFormat.sniff(path: temporaryFile.path) else {
            throw TelegramError.backend("The bot's link did not return an audio file.")
        }
        guard format.isPlayableByAVFoundation else { throw TelegramError.unsupportedFormat(format.displayName) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporaryFile, to: destination)
    }
}

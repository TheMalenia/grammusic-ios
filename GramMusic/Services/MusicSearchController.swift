import Foundation
import Observation

/// Owns request identity, tab caches and pagination independently of SwiftUI and TDLib.
/// A late response must never replace a newer query or a different source's rows.
@MainActor @Observable
final class MusicSearchController {
    typealias Fetch = @MainActor (MusicSearchSource, String, String) async throws -> MusicSearchPage

    private(set) var tracks: [AudioTrack] = []
    private(set) var isSearching = false
    private(set) var isLoadingMore = false
    private(set) var error: String?
    private(set) var failure: MusicSearchFailure?
    private(set) var nonAudioResultCount = 0
    private(set) var nextOffset = ""
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var source: MusicSearchSource = .telegram
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var pages: [String: MusicSearchPage] = [:]
    @ObservationIgnored private var pageOffsets: [String: Set<String>] = [:]
    @ObservationIgnored private var usedOffsets = Set<String>()

    private static let botResponseRetryPolicy = Retry.Policy(
        attempts: 2, initialDelay: .milliseconds(500), maxDelay: .milliseconds(500), jitter: 0.15
    )

    func search(source: MusicSearchSource, query: String, debounce: Duration? = nil,
                refresh: Bool = false,
                sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                retrySleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                fetch: Fetch) async {
        revision += 1
        let request = revision
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if term != self.query { pages.removeAll(); pageOffsets.removeAll() }
        self.query = term
        self.source = source
        tracks = []; error = nil; failure = nil; nextOffset = ""; nonAudioResultCount = 0
        isSearching = false; isLoadingMore = false; usedOffsets = []
        guard !term.isEmpty else { return }
        if !refresh, let cached = pages[source.requestKey] {
            usedOffsets = pageOffsets[source.requestKey] ?? []
            apply(cached)
            return
        }
        isSearching = true
        do {
            // Keep a short typing debounce for bots; local Telegram search keeps its existing policy.
            try await sleep(debounce ?? (source.isTelegram ? .milliseconds(280) : .milliseconds(150)))
            try Task.checkCancellation()
            let page = try await fetchPage(source: source, query: term, offset: "", request: request,
                                           retrySleep: retrySleep, fetch: fetch)
            try Task.checkCancellation()
            guard request == revision else { return }
            pages[source.requestKey] = page
            pageOffsets[source.requestKey] = []
            apply(page)
            isSearching = false
        } catch {
            guard request == revision else { return }
            isSearching = false
            if !(error is CancellationError) {
                self.error = error.localizedDescription
                failure = MusicSearchFailure(error: error, source: source)
            }
        }
    }

    func loadMore(
        retrySleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        fetch: Fetch
    ) async {
        guard !isSearching, !isLoadingMore, !nextOffset.isEmpty else { return }
        let request = revision
        let offset = nextOffset
        isLoadingMore = true; error = nil; failure = nil
        do {
            let page = try await fetchPage(source: source, query: query, offset: offset, request: request,
                                           retrySleep: retrySleep, fetch: fetch)
            try Task.checkCancellation()
            guard request == revision else { return }
            usedOffsets.insert(offset)
            let next = usedOffsets.contains(page.nextOffset) ? "" : page.nextOffset
            let merged = MusicSearchPage(tracks: AudioSearch.deduped(tracks + page.tracks), nextOffset: next,
                                        nonAudioResultCount: nonAudioResultCount + page.nonAudioResultCount)
            pages[source.requestKey] = merged
            pageOffsets[source.requestKey] = usedOffsets
            apply(merged)
            isLoadingMore = false
        } catch {
            guard request == revision else { return }
            isLoadingMore = false
            if !(error is CancellationError) {
                self.error = error.localizedDescription
                failure = MusicSearchFailure(error: error, source: source, isPagination: true)
            }
        }
    }

    private func apply(_ page: MusicSearchPage) {
        tracks = page.tracks; nextOffset = page.nextOffset
        nonAudioResultCount = page.nonAudioResultCount
    }

    private func fetchPage(
        source: MusicSearchSource,
        query: String,
        offset: String,
        request: Int,
        retrySleep: @MainActor (Duration) async throws -> Void,
        fetch: Fetch
    ) async throws -> MusicSearchPage {
        guard case .bot = source else { return try await fetch(source, query, offset) }
        return try await Retry.run(Self.botResponseRetryPolicy,
                                   isRetryable: Self.isBotResponseRetryable,
                                   sleep: retrySleep) {
            guard request == self.revision else { throw CancellationError() }
            return try await fetch(source, query, offset)
        }
    }

    /// InlineMusicSearch already retries transport errors. This second, bounded layer only covers
    /// bot response failures TDLib reports as ordinary backend errors, so retries never multiply.
    private static func isBotResponseRetryable(_ error: Error) -> Bool {
        guard !(error is CancellationError), !TelegramError.isRetryable(error) else { return false }
        let text = error.localizedDescription.uppercased()
        guard !text.contains("FLOOD_WAIT"), !text.contains("TOO MANY"),
              !text.contains("OFFLINE"), !text.contains("NO INTERNET"),
              !text.contains("INTERNET CONNECTION"), !text.contains("NO CONNECTION"),
              !text.contains("NOT CONNECTED"), !text.contains("NETWORK UNAVAILABLE") else { return false }
        return text.contains("502") || text.contains("BOT_RESPONSE_TIMEOUT") ||
            text.contains("BOT IS NOT RESPONDING") || text.contains("TIMED OUT") ||
            text.contains("TIMEOUT") || text.contains("CONNECTION LOST") ||
            text.contains("CONNECTION RESET") || text.contains("TEMPORARILY UNAVAILABLE")
    }
}

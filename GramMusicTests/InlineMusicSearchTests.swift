import XCTest
@testable import GramMusic

@MainActor
final class InlineMusicSearchTests: XCTestCase {
    private func results() -> AppInlineQueryResults {
        AppInlineQueryResults(inlineQueryId: 7, botUserId: 42, results: [], nextOffset: "next")
    }

    func test_contextIsPreparedOnceAcrossQueriesAndPages() async throws {
        let context = InlineMusicSearchContext()
        var preparations = 0
        for (query, offset) in [("first song", ""), ("first song", "page2"), ("another song", "")] {
            _ = try await InlineMusicSearch.load(bot: MusicSearchBot(id: 42, username: "musicbot"),
                query: query, offset: offset, context: {
                    try await context.resolve { preparations += 1; return 123 }
                }, fetch: { _, chat, _, _ in
                    XCTAssertEqual(chat, 123)
                    return self.results()
                })
        }
        XCTAssertEqual(preparations, 1)
    }

    func test_concurrentSearchesShareContextPreparation() async throws {
        let context = InlineMusicSearchContext()
        var preparations = 0
        var response: CheckedContinuation<Int64, Never>?
        let first = Task {
            try await context.resolve {
                preparations += 1
                return await withCheckedContinuation { response = $0 }
            }
        }
        while response == nil { await Task.yield() }
        let second = Task {
            try await context.resolve { preparations += 1; return 456 }
        }
        await Task.yield()
        response?.resume(returning: 123)
        let values = try await [first.value, second.value]
        XCTAssertEqual(values, [123, 123])
        XCTAssertEqual(preparations, 1)
    }

    func test_contextInvalidationDiscardsLateResultsFromPreviousSession() async throws {
        let context = InlineMusicSearchContext()
        var response: CheckedContinuation<Int64, Never>?
        let old = Task {
            try await context.resolve { await withCheckedContinuation { response = $0 } }
        }
        while response == nil { await Task.yield() }
        context.clear()
        let new = try await context.resolve { 456 }
        response?.resume(returning: 123)
        do { _ = try await old.value; XCTFail("Old session must not populate the cache") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cached = try await context.resolve { XCTFail("New session should be cached"); return 0 }
        XCTAssertEqual(new, 456)
        XCTAssertEqual(cached, 456)
    }

    func test_failedContextPreparationCanBeRetried() async throws {
        let context = InlineMusicSearchContext()
        do {
            _ = try await context.resolve { throw TelegramError.transient("Disconnected") }
            XCTFail("Expected failure")
        } catch { }
        let resolved = try await context.resolve { 123 }
        XCTAssertEqual(resolved, 123)
    }

    func test_searchUsesSavedMessagesContextAndPreservesQueryAndOffset() async throws {
        var contexts = 0
        let page = try await InlineMusicSearch.load(bot: MusicSearchBot(id: 42, username: "musicbot"), query: "Halo", offset: "page2", context: {
            contexts += 1
            return 123
        }, fetch: { bot, chat, query, offset in
            XCTAssertEqual(bot, 42)
            XCTAssertEqual(chat, 123)
            XCTAssertEqual(query, "Halo")
            XCTAssertEqual(offset, "page2")
            return self.results()
        })
        XCTAssertEqual(contexts, 1)
        XCTAssertEqual(page.nextOffset, "next")
    }

    func test_unspecifiedChatContextCannotReachBot() async {
        do {
            _ = try await InlineMusicSearch.load(bot: MusicSearchBot(id: 42, username: "musicbot"), query: "song", offset: "", context: { 0 }, fetch: { _, _, _, _ in
                XCTFail("A real Saved Messages context is required")
                return self.results()
            })
            XCTFail("Expected context failure")
        } catch { XCTAssertFalse(TelegramError.isRetryable(error)) }
    }

    func test_botTimeoutRetriesOnceWithoutResolvingContextAgain() async throws {
        var requests = 0
        var contexts = 0
        var delays: [Duration] = []
        _ = try await InlineMusicSearch.load(bot: MusicSearchBot(id: 42, username: "musicbot"), query: "song", offset: "", context: {
            contexts += 1
            return 123
        }, sleep: { delays.append($0) }, fetch: { _, chat, _, _ in
            XCTAssertEqual(chat, 123)
            requests += 1
            if requests == 1 { throw TelegramError.transient("The bot is not responding (502)") }
            return self.results()
        })
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(contexts, 1)
        XCTAssertEqual(delays.count, 1)
    }

    func test_repeatedTimeoutStopsAfterTwoAttempts() async {
        var requests = 0
        do {
            _ = try await InlineMusicSearch.load(bot: MusicSearchBot(id: 42, username: "musicbot"), query: "song", offset: "", context: { 123 }, sleep: { _ in },
                fetch: { _, _, _, _ in
                    requests += 1
                    throw TelegramError.transient("The bot is not responding (502)")
                })
            XCTFail("Expected final timeout")
        } catch { XCTAssertTrue(TelegramError.isRetryable(error)) }
        XCTAssertEqual(requests, 2)
    }

    func test_floodWaitDoesNotRetry() async {
        var requests = 0
        do {
            _ = try await InlineMusicSearch.load(bot: MusicSearchBot(id: 42, username: "musicbot"), query: "song", offset: "", context: { 123 }, sleep: { _ in XCTFail("No delay") },
                fetch: { _, _, _, _ in
                    requests += 1
                    throw TelegramError.backend("Too many attempts. Please wait 30s and try again.")
                })
            XCTFail("Expected rate limit")
        } catch { XCTAssertFalse(TelegramError.isRetryable(error)) }
        XCTAssertEqual(requests, 1)
    }

    func test_cancellationDuringRetryDoesNotSendAnotherQuery() async {
        var requests = 0
        let task = Task {
            try await InlineMusicSearch.load(bot: MusicSearchBot(id: 42, username: "musicbot"), query: "song", offset: "", context: { 123 }, sleep: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }, fetch: { _, _, _, _ in
                requests += 1
                throw TelegramError.transient("The bot is not responding (502)")
            })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests, 1)
    }
    func test_prefixIsSentExactlyOnceOnFirstPageNextPageAndRetry() async throws {
        let bot = MusicSearchBot(id: 42, username: "musicbot", displayName: "Music", queryPrefix: "music")
        var queries: [String] = []
        var offsets: [String] = []
        for offset in ["", "page2"] {
            var attempt = 0
            _ = try await InlineMusicSearch.load(bot: bot, query: " Halo ", offset: offset,
                context: { 123 }, sleep: { _ in }, fetch: { _, _, query, receivedOffset in
                    queries.append(query)
                    offsets.append(receivedOffset)
                    attempt += 1
                    if attempt == 1 { throw TelegramError.transient("502") }
                    return self.results()
                })
        }
        XCTAssertEqual(queries, ["music Halo", "music Halo", "music Halo", "music Halo"])
        XCTAssertEqual(offsets, ["", "", "page2", "page2"])
        XCTAssertEqual(bot.inlineQuery(""), "music")
        XCTAssertEqual(MusicSearchBot(id: 42, username: "musicbot").inlineQuery(" Halo "), "Halo")
    }

}

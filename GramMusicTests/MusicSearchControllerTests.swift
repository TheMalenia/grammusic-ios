import XCTest
@testable import GramMusic

@MainActor
final class MusicSearchControllerTests: XCTestCase {
    private let bot = MusicSearchSource.bot(MusicSearchBot(id: 42, username: "musicbot"))
    private func track(_ id: String) -> AudioTrack {
        AudioTrack(chatId: 0, messageId: 0, fileId: 1, remoteUniqueId: id,
                   remoteFileId: "remote-" + id, title: id, performer: "Artist", duration: 100)
    }

    func test_botTypingDelayIsShorterAndExplicitSearchCanSkipIt() async {
        let controller = MusicSearchController()
        var delays: [Duration] = []
        let fetch: MusicSearchController.Fetch = { _, _, _ in MusicSearchPage(tracks: []) }
        await controller.search(source: bot, query: "one", sleep: { delays.append($0) }, fetch: fetch)
        await controller.search(source: .telegram, query: "two", sleep: { delays.append($0) }, fetch: fetch)
        await controller.search(source: bot, query: "three", debounce: .zero, sleep: { delays.append($0) }, fetch: fetch)
        XCTAssertEqual(delays, [.milliseconds(150), .milliseconds(280), .zero])
    }

    func test_searchQueriesOnlySelectedSourceAndKeepsQueryOnTabSwitch() async {
        let controller = MusicSearchController()
        var calls: [String] = []
        let fetch: MusicSearchController.Fetch = { source, query, offset in
            calls.append("\(source.id)|\(query)|\(offset)")
            return MusicSearchPage(tracks: [self.track(source.id)])
        }
        await controller.search(source: .telegram, query: "  Halo  ", debounce: .zero, fetch: fetch)
        await controller.search(source: bot, query: "Halo", debounce: .zero, fetch: fetch)
        XCTAssertEqual(calls, ["telegram|Halo|", "bot:42|Halo|"])
        XCTAssertEqual(controller.tracks.first?.remoteUniqueId, "bot:42")
    }

    func test_tabCacheDoesNotLeakIntoNewQuery() async {
        let controller = MusicSearchController()
        var calls = 0
        let fetch: MusicSearchController.Fetch = { source, query, _ in
            calls += 1
            return MusicSearchPage(tracks: [self.track(source.id + query)])
        }
        await controller.search(source: .telegram, query: "one", debounce: .zero, fetch: fetch)
        await controller.search(source: bot, query: "one", debounce: .zero, fetch: fetch)
        await controller.search(source: .telegram, query: "one", debounce: .zero, fetch: fetch)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(controller.tracks.first?.remoteUniqueId, "telegramone")
        await controller.search(source: .telegram, query: "two", debounce: .zero, fetch: fetch)
        await controller.search(source: bot, query: "two", debounce: .zero, fetch: fetch)
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(controller.tracks.first?.remoteUniqueId, "bot:42two")
    }

    func test_lateResponseFromPreviousSourceCannotReplaceCurrentRows() async {
        let controller = MusicSearchController()
        var response: CheckedContinuation<MusicSearchPage, Never>?
        let old = Task { @MainActor in
            await controller.search(source: .telegram, query: "song", debounce: .zero) { _, _, _ in
                await withCheckedContinuation { response = $0 }
            }
        }
        while response == nil { await Task.yield() }
        await controller.search(source: bot, query: "song", debounce: .zero) { _, _, _ in
            MusicSearchPage(tracks: [self.track("new")])
        }
        response?.resume(returning: MusicSearchPage(tracks: [track("old")]))
        await old.value
        XCTAssertEqual(controller.tracks.map(\.remoteUniqueId), ["new"])
        XCTAssertFalse(controller.isSearching)
    }

    func test_clearingQueryInvalidatesAnInFlightResponse() async {
        let controller = MusicSearchController()
        var response: CheckedContinuation<MusicSearchPage, Never>?
        let old = Task { @MainActor in
            await controller.search(source: bot, query: "song", debounce: .zero) { _, _, _ in
                await withCheckedContinuation { response = $0 }
            }
        }
        while response == nil { await Task.yield() }
        await controller.search(source: bot, query: "  ", debounce: .zero) { _, _, _ in
            XCTFail("An empty query must not reach a bot")
            return MusicSearchPage(tracks: [])
        }
        response?.resume(returning: MusicSearchPage(tracks: [track("old")]))
        await old.value
        XCTAssertTrue(controller.tracks.isEmpty)
        XCTAssertFalse(controller.isSearching)
    }

    func test_cancellationDuringDebounceDoesNotIssueQueryOrShowError() async {
        let controller = MusicSearchController()
        let task = Task { @MainActor in
            await controller.search(source: bot, query: "song", debounce: .seconds(10)) { _, _, _ in
                XCTFail("Cancelled debounce must not issue a query")
                return MusicSearchPage(tracks: [])
            }
        }
        await Task.yield()
        task.cancel(); await task.value
        XCTAssertNil(controller.error)
        XCTAssertFalse(controller.isSearching)
    }

    func test_failureIsVisibleAndRetryCanRecover() async {
        let controller = MusicSearchController()
        await controller.search(source: bot, query: "song", debounce: .zero) { _, _, _ in
            throw TelegramError.backend("Bot unavailable")
        }
        XCTAssertEqual(controller.error, "Bot unavailable")
        XCTAssertFalse(controller.isSearching)
        await controller.search(source: bot, query: "song", debounce: .zero, refresh: true) { _, _, _ in
            MusicSearchPage(tracks: [self.track("recovered")])
        }
        XCTAssertNil(controller.error)
        XCTAssertEqual(controller.tracks.count, 1)
    }

    func test_paginationDeduplicatesPreservesBotOrderAndStopsRepeatedOffsets() async {
        let controller = MusicSearchController()
        await controller.search(source: bot, query: "song", debounce: .zero) { _, _, _ in
            MusicSearchPage(tracks: [self.track("b"), self.track("a")], nextOffset: "page2")
        }
        await controller.loadMore { source, query, offset in
            XCTAssertEqual(source, self.bot); XCTAssertEqual(query, "song"); XCTAssertEqual(offset, "page2")
            return MusicSearchPage(tracks: [self.track("a"), self.track("c")], nextOffset: "page2")
        }
        XCTAssertEqual(controller.tracks.map(\.remoteUniqueId), ["b", "a", "c"])
        XCTAssertTrue(controller.nextOffset.isEmpty)
    }

    func test_paginationCycleDetectionSurvivesSwitchingTabs() async {
        let controller = MusicSearchController()
        await controller.search(source: bot, query: "song", debounce: .zero) { _, _, _ in
            MusicSearchPage(tracks: [self.track("a")], nextOffset: "page2")
        }
        await controller.loadMore { _, _, _ in MusicSearchPage(tracks: [self.track("b")], nextOffset: "page3") }
        await controller.search(source: .telegram, query: "song", debounce: .zero) { _, _, _ in MusicSearchPage(tracks: []) }
        await controller.search(source: bot, query: "song", debounce: .zero) { _, _, _ in
            XCTFail("Switching back should use the cached page")
            return MusicSearchPage(tracks: [])
        }
        await controller.loadMore { _, _, _ in MusicSearchPage(tracks: [self.track("c")], nextOffset: "page2") }
        XCTAssertTrue(controller.nextOffset.isEmpty)
        XCTAssertEqual(controller.tracks.map(\.remoteUniqueId), ["a", "b", "c"])
    }

    func test_paginationFailureKeepsLoadedSongsAndCanRetry() async {
        let controller = MusicSearchController()
        await controller.search(source: bot, query: "song", debounce: .zero) { _, _, _ in
            MusicSearchPage(tracks: [self.track("a")], nextOffset: "page2")
        }
        await controller.loadMore { _, _, _ in throw TelegramError.backend("Network failed") }
        XCTAssertEqual(controller.tracks.count, 1)
        XCTAssertEqual(controller.nextOffset, "page2")
        XCTAssertEqual(controller.error, "Network failed")
        XCTAssertTrue(controller.failure?.isPagination == true)
        await controller.loadMore { _, _, _ in MusicSearchPage(tracks: [self.track("b")]) }
        XCTAssertEqual(controller.tracks.count, 2)
        XCTAssertNil(controller.error)
        XCTAssertNil(controller.failure)
    }

    func test_latePaginationCannotAppendToADifferentQuery() async {
        let controller = MusicSearchController()
        await controller.search(source: bot, query: "old", debounce: .zero) { _, _, _ in
            MusicSearchPage(tracks: [self.track("a")], nextOffset: "page2")
        }
        var response: CheckedContinuation<MusicSearchPage, Never>?
        let old = Task { @MainActor in
            await controller.loadMore { _, _, _ in await withCheckedContinuation { response = $0 } }
        }
        while response == nil { await Task.yield() }
        await controller.search(source: bot, query: "new", debounce: .zero) { _, _, _ in
            MusicSearchPage(tracks: [self.track("new")])
        }
        response?.resume(returning: MusicSearchPage(tracks: [track("old")]))
        await old.value
        XCTAssertEqual(controller.tracks.map(\.remoteUniqueId), ["new"])
        XCTAssertFalse(controller.isLoadingMore)
    }

    func test_nonAudioInlineResultsNeverBecomeSongs() {
        let audio = AppInlineQueryResult(id: "audio", title: "Song", description: nil, type: "audio", track: track("a"))
        let link = AppInlineQueryResult(id: "article", title: "Visit bot", description: nil, type: "article")
        let page = MusicSearchPage(inlineResults: AppInlineQueryResults(inlineQueryId: 1, botUserId: 42,
                                                                       results: [audio, link, audio], nextOffset: "next"))
        XCTAssertEqual(page.tracks.map(\.remoteUniqueId), ["a"])
        XCTAssertEqual(page.nonAudioResultCount, 1)
        XCTAssertEqual(page.nextOffset, "next")
    }
    func test_botTimeoutHasActionablePresentationAndNewSearchClearsIt() async {
        let controller = MusicSearchController()
        await controller.search(source: bot, query: "song", debounce: .zero) { _, _, _ in
            throw TelegramError.transient("The bot is not responding (502)")
        }
        XCTAssertTrue(controller.error?.contains("502") == true, "Keep the transport diagnostic available")
        XCTAssertEqual(controller.failure?.title, "Bot timed out")
        XCTAssertFalse(controller.failure?.message.contains("502") == true)
        XCTAssertTrue(controller.failure?.message.contains(bot.label) == true)
        await controller.search(source: .telegram, query: "other", debounce: .zero) { _, _, _ in
            MusicSearchPage(tracks: [])
        }
        XCTAssertNil(controller.error)
        XCTAssertNil(controller.failure)
    }

    func test_botResponseTimeoutGetsOneBoundedAutomaticRetry() async {
        let controller = MusicSearchController()
        var calls = 0
        var delays: [Duration] = []
        await controller.search(source: bot, query: "song", debounce: .zero,
                                retrySleep: { delays.append($0) }) { _, _, _ in
            calls += 1
            throw TelegramError.backend("BOT_RESPONSE_TIMEOUT (502)")
        }

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(delays.count, 1)
        XCTAssertEqual(controller.failure?.title, "Bot timed out")
        XCTAssertTrue(controller.failure?.canRetry == true)
    }

    func test_botPaginationTimeoutRetriesOnePageAndRetainsLoadedSongs() async {
        let controller = MusicSearchController()
        await controller.search(source: bot, query: "song", debounce: .zero) { _, _, _ in
            MusicSearchPage(tracks: [self.track("first")], nextOffset: "page2")
        }
        var calls = 0
        await controller.loadMore(retrySleep: { _ in }) { _, _, _ in
            calls += 1
            if calls == 1 { throw TelegramError.backend("BOT_RESPONSE_TIMEOUT") }
            return MusicSearchPage(tracks: [self.track("second")])
        }

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(controller.tracks.map(\.remoteUniqueId), ["first", "second"])
        XCTAssertNil(controller.failure)
    }

    func test_sourceSwitchDuringBotRetryDoesNotIssueAnotherOldRequest() async {
        let controller = MusicSearchController()
        var botCalls = 0
        var retryDelay: CheckedContinuation<Void, Never>?
        let oldSearch = Task { @MainActor in
            await controller.search(source: bot, query: "song", debounce: .zero,
                                    retrySleep: { _ in await withCheckedContinuation { retryDelay = $0 } }) { _, _, _ in
                botCalls += 1
                throw TelegramError.backend("BOT_RESPONSE_TIMEOUT")
            }
        }
        while retryDelay == nil { await Task.yield() }

        await controller.search(source: .telegram, query: "new", debounce: .zero) { _, _, _ in
            MusicSearchPage(tracks: [self.track("telegram-result")])
        }
        retryDelay?.resume()
        await oldSearch.value

        XCTAssertEqual(botCalls, 1)
        XCTAssertEqual(controller.tracks.map(\.remoteUniqueId), ["telegram-result"])
        XCTAssertFalse(controller.isSearching)
    }

    func test_cancellationDuringBotRetryDoesNotIssueAnotherRequestOrShowFailure() async {
        let controller = MusicSearchController()
        var calls = 0
        let search = Task { @MainActor in
            await controller.search(source: bot, query: "song", debounce: .zero,
                                    retrySleep: { _ in try await Task.sleep(for: .seconds(30)) }) { _, _, _ in
                calls += 1
                throw TelegramError.backend("BOT_RESPONSE_TIMEOUT")
            }
        }
        while calls == 0 { await Task.yield() }
        search.cancel()
        await search.value

        XCTAssertEqual(calls, 1)
        XCTAssertNil(controller.failure)
        XCTAssertFalse(controller.isSearching)
    }

    func test_prefixEditInvalidatesCachedResultsButDisplayNameEditReusesThem() async {
        let controller = MusicSearchController()
        let original = MusicSearchBot(id: 42, username: "musicbot")
        let prefixed = MusicSearchBot(id: 42, username: "musicbot", queryPrefix: "music")
        let renamed = MusicSearchBot(id: 42, username: "musicbot", displayName: "My music", queryPrefix: "music")
        var calls = 0
        let fetch: MusicSearchController.Fetch = { source, _, _ in
            calls += 1
            return MusicSearchPage(tracks: [self.track(source.requestKey)])
        }
        await controller.search(source: .bot(original), query: "Halo", debounce: .zero, fetch: fetch)
        await controller.search(source: .bot(prefixed), query: "Halo", debounce: .zero, fetch: fetch)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(controller.tracks.first?.remoteUniqueId, MusicSearchSource.bot(prefixed).requestKey)
        await controller.search(source: .bot(renamed), query: "Halo", debounce: .zero, fetch: fetch)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(MusicSearchSource.bot(original).id, MusicSearchSource.bot(prefixed).id)
    }

}

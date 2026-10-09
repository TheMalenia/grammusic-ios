import XCTest
@testable import GramMusic

final class MusicSearchFailureTests: XCTestCase {
    private let bot = MusicSearchSource.bot(MusicSearchBot(id: 42, username: "deezermusicbot"))

    func test_502ExplainsTimeoutAndNamesBotWithoutShowingTransportCode() {
        let failure = MusicSearchFailure(error: TelegramError.transient("The bot is not responding (502)"), source: bot)
        XCTAssertEqual(failure.title, "Bot timed out")
        XCTAssertTrue(failure.message.contains("@deezermusicbot"))
        XCTAssertTrue(failure.message.contains("Try again"))
        XCTAssertFalse(failure.message.contains("502"))
        XCTAssertTrue(failure.canRetry)
    }

    func test_offlineExplainsSavedMusicFallback() {
        let failure = MusicSearchFailure(error: URLError(.notConnectedToInternet), source: bot)
        XCTAssertEqual(failure.title, "You're offline")
        XCTAssertTrue(failure.message.contains("saved music"))
    }

    func test_rateLimitKeepsWaitInstructionAndDoesNotOfferImmediateRetry() {
        let failure = MusicSearchFailure(error: TelegramError.backend("Too many attempts. Please wait 30s and try again."), source: bot)
        XCTAssertTrue(failure.message.contains("30s"))
        XCTAssertFalse(failure.canRetry)
    }

    func test_paginationFailureExplainsLoadedSongsRemainAvailable() {
        let failure = MusicSearchFailure(error: URLError(.networkConnectionLost), source: bot, isPagination: true)
        XCTAssertEqual(failure.title, "Couldn't load more songs")
        XCTAssertTrue(failure.isPagination)
        XCTAssertTrue(failure.message.contains("loaded songs"))
    }

    func test_botResponseErrorDoesNotClaimTheBotIsBroken() {
        let failure = MusicSearchFailure(error: TelegramError.backend("BOT_RESPONSE_INVALID (400)"), source: bot)
        XCTAssertEqual(failure.title, "Bot couldn't complete the search")
        XCTAssertTrue(failure.message.contains("returned an error"))
        XCTAssertTrue(failure.message.contains("choose another search source"))
        XCTAssertFalse(failure.message.localizedCaseInsensitiveContains("broken"))
    }

    func test_paginationTimeoutKeepsExistingResultsAndNamesTheTimedOutSource() {
        let failure = MusicSearchFailure(error: TelegramError.backend("BOT_RESPONSE_TIMEOUT"), source: bot,
                                         isPagination: true)
        XCTAssertTrue(failure.message.contains("loaded songs are still here"))
        XCTAssertTrue(failure.message.contains("@deezermusicbot"))
        XCTAssertTrue(failure.message.contains("page in time"))
    }

    func test_inlineDisabledSuggestsAnotherBotRatherThanRetry() {
        let failure = MusicSearchFailure(error: TelegramError.backend("BOT_INLINE_DISABLED (400)"), source: bot)
        XCTAssertFalse(failure.canRetry)
        XCTAssertTrue(failure.message.contains("another bot"))
    }
}

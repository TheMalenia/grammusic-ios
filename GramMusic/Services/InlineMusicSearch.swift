import Foundation

/// Inline searches use a real private-chat context, without ever sending a result/message.
enum InlineMusicSearch {
    @MainActor
    static func load(
        bot: MusicSearchBot, query: String, offset: String,
        context: () async throws -> Int64,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        fetch: (Int64, Int64, String, String) async throws -> AppInlineQueryResults
    ) async throws -> MusicSearchPage {
        try Task.checkCancellation()
        let chatID = try await context()
        guard chatID != 0 else { throw TelegramError.backend("Couldn't prepare the Saved Messages search context. Try again.") }
        return try await Retry.run(.init(attempts: 2, initialDelay: .milliseconds(600)), sleep: sleep) {
            try Task.checkCancellation()
            let results = try await fetch(bot.id, chatID, bot.inlineQuery(query), offset)
            try Task.checkCancellation()
            return MusicSearchPage(inlineResults: results)
        }
    }
}

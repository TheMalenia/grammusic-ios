import Foundation

/// An opt-in inline bot. The stable Telegram user ID survives username changes.
struct MusicSearchBot: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: Int64
    let username: String
    let displayName: String?
    let queryPrefix: String?
    var label: String { displayName ?? "@" + username }
    var connectionInput: String { ["@" + username, queryPrefix].compactMap { $0 }.joined(separator: " ") }

    init(id: Int64, username: String, displayName: String? = nil, queryPrefix: String? = nil) {
        self.id = id
        self.username = username
        self.displayName = Self.optionalText(displayName)
        self.queryPrefix = Self.optionalText(queryPrefix)
    }

    func inlineQuery(_ text: String) -> String {
        [queryPrefix, Self.optionalText(text)].compactMap { $0 }.joined(separator: " ")
    }

    static func parseConnection(_ input: String) throws -> (username: String, queryPrefix: String?) {
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        let username = try normalizedUsername(parts.first.map(String.init) ?? "")
        return (username, parts.count > 1 ? optionalText(String(parts[1])) : nil)
    }

    private static func optionalText(_ input: String?) -> String? {
        guard let trimmed = input?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func normalizedUsername(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") { value.removeFirst() }
        guard (5...32).contains(value.count),
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_").contains($0) }),
              value.first?.isLetter == true else {
            throw TelegramError.backend("Enter a bot username, such as @Deezermusicbot.")
        }
        return value.lowercased()
    }
}

enum MusicSearchSource: Hashable, Identifiable, Sendable {
    case telegram
    case bot(MusicSearchBot)

    var id: String {
        switch self {
        case .telegram: "telegram"
        case .bot(let bot): "bot:\(bot.id)"
        }
    }
    /// Changing a bot's query prefix invalidates search caches without changing its default/tab ID.
    var requestKey: String {
        switch self {
        case .telegram: id
        case .bot(let bot): id + "|" + (bot.queryPrefix ?? "")
        }
    }
    var label: String {
        switch self {
        case .telegram: "Telegram"
        case .bot(let bot): bot.label
        }
    }
    var isTelegram: Bool { self == .telegram }
}

import Foundation

/// A lightweight view of a Telegram chat the user belongs to.
struct TelegramChat: Identifiable, Hashable, Sendable, Codable {
    let id: Int64
    let title: String
    let kind: Kind
    var userId: Int64?
    var photoData: Data?
    var photoId: String?
    var audioCount: Int?
    var lastAudioDate: Date?
    var username: String?

    var kindLabel: String {
        switch kind {
        case .savedMessages: "Saved Messages"
        case .channel: "Channel"
        case .group: "Group"
        case .privateChat: "Direct chat"
        case .bot: "Bot"
        case .secret: "Secret chat"
        case .unknown: "Chat"
        }
    }

    /// "Chat · 124 tracks" meta line (falls back to just "Chat").
    var audioMeta: String {
        guard let n = audioCount else { return "Chat" }
        return "Chat · \(n) track\(n == 1 ? "" : "s")"
    }

    enum Kind: String, Sendable, Codable {
        case savedMessages
        case channel
        case group
        case privateChat
        case bot
        case secret
        case unknown

        var symbolName: String {
            switch self {
            case .savedMessages: "bookmark.fill"
            case .channel: "megaphone.fill"
            case .group: "person.3.fill"
            case .privateChat: "person.fill"
            case .bot: "wand.and.stars"
            case .secret: "lock.fill"
            case .unknown: "bubble.left.fill"
            }
        }
    }
}

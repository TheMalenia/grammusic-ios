import Foundation

/// Represents an inline keyboard attached to a message (usually from a bot).
public struct ReplyMarkup: Equatable, Sendable, Hashable {
    public let rows: [[InlineKeyboardButton]]
    
    public init(rows: [[InlineKeyboardButton]]) {
        self.rows = rows
    }
}

public struct InlineKeyboardButton: Equatable, Sendable, Hashable, Identifiable {
    public let id: String // Combined row/col or unique text for Identifiable
    public let text: String
    public let type: ButtonType
    
    public enum ButtonType: Equatable, Sendable, Hashable {
        case callback(Data)
        case url(String)
        case switchInline(query: String, sameChat: Bool)
        case unsupported
    }
    
    public init(id: String = UUID().uuidString, text: String, type: ButtonType) {
        self.id = id
        self.text = text
        self.type = type
    }
}

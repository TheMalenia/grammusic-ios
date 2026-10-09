import Foundation

struct ChatMessage: Equatable, Identifiable, Sendable, Hashable {
    let id: Int64
    let chatId: Int64
    let senderId: Int64
    let date: Date
    let content: MessageContent
    let replyMarkup: ReplyMarkup?
    
    init(id: Int64, chatId: Int64, senderId: Int64, date: Date, content: MessageContent, replyMarkup: ReplyMarkup? = nil) {
        self.id = id
        self.chatId = chatId
        self.senderId = senderId
        self.date = date
        self.content = content
        self.replyMarkup = replyMarkup
    }
}

enum MessageContent: Equatable, Sendable, Hashable {
    case text(String)
    case audio(track: AudioTrack, caption: String?)
    case unsupported
}

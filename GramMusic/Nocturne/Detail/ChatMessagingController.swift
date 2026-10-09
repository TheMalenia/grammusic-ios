import Foundation
import SwiftUI

@MainActor
@Observable
final class ChatMessagingController {
    let chatId: Int64
    private let telegram: TelegramService
    
    var messages: [ChatMessage] = []
    var isLoading = false
    var loadingMore = false
    var error: String?
    var canSendMessages: Bool = false
    
    // Inline Query State
    var inlineResults: [AppInlineQueryResult] = []
    var isInlineQueryLoading: Bool = false
    var currentInlineBotUsername: String?
    var currentInlineQuery: String?
    var currentInlineQueryId: Int64?
    var currentInlineBotUserId: Int64?
    private var inlineQueryTask: Task<Void, Never>?
    
    var nextFromId: Int64? = 0
    private var updateTask: Task<Void, Never>?
    
    init(chatId: Int64, telegram: TelegramService) {
        self.chatId = chatId
        self.telegram = telegram
        self.messages = telegram.cachedMessages(chatId)
    }
    
    func start() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await telegram.chatHistory(in: chatId, limit: 50, fromMessageId: 0)
            self.messages = page
            self.telegram.cacheMessages(page, chatId: chatId)
            self.nextFromId = page.last?.id
            self.canSendMessages = await telegram.canSendMessages(in: chatId)
            
            // Listen for real-time updates
            updateTask?.cancel()
            updateTask = Task { [weak self] in
                guard let self = self else { return }
                for await update in self.telegram.messageUpdates(for: self.chatId) {
                    self.handleUpdate(update)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
    
    func stop() {
        updateTask?.cancel()
        updateTask = nil
        inlineQueryTask?.cancel()
        inlineQueryTask = nil
    }
    
    func loadMore() async {
        guard let from = nextFromId, !loadingMore, from != 0 else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await telegram.chatHistory(in: chatId, limit: 50, fromMessageId: from)
            let existingIds = Set(messages.map { $0.id })
            let fresh = page.filter { !existingIds.contains($0.id) }
            
            if fresh.isEmpty {
                nextFromId = nil
            } else {
                messages.append(contentsOf: fresh)
                // sort messages by date descending (newest first is typical for chat history arrays)
                messages.sort { $0.date > $1.date }
                nextFromId = page.last?.id
            }
        } catch {
            print("ChatMessagingController loadMore error: \(error)")
        }
    }
    
    func send(text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await telegram.sendTextMessage(to: chatId, text: text)
    }
    
    func send(audio track: AudioTrack, caption: String?) async {
        await telegram.sendAudioMessage(to: chatId, track: track, caption: caption)
    }
    
    func tapInlineButton(messageId: Int64, button: InlineKeyboardButton) async {
        switch button.type {
        case .callback(let data):
            await telegram.sendBotCallbackQuery(chatId: chatId, messageId: messageId, payload: data)
        case .url(let urlStr):
            if let url = URL(string: urlStr) {
                #if os(iOS)
                await UIApplication.shared.open(url)
                #endif
            }
        default:
            break
        }
    }
    
    private func handleUpdate(_ update: MessageUpdate) {
        switch update {
        case .new(let message):
            // Insert at beginning assuming newest first
            if !messages.contains(where: { $0.id == message.id }) {
                messages.insert(message, at: 0)
                messages.sort { $0.date > $1.date }
            }
        case .edited(let message):
            if let idx = messages.firstIndex(where: { $0.id == message.id }) {
                messages[idx] = message
            }
        case .deleted(let ids):
            let idSet = Set(ids)
            messages.removeAll { idSet.contains($0.id) }
        }
    }
    
    func handleInputTextChanged(_ text: String) {
        inlineQueryTask?.cancel()
        
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^@([a-zA-Z0-9_]{3,32})(?:\s(.*))?$"#
        
        if trimmed.range(of: pattern, options: .regularExpression) != nil {
            let split = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let botUsername = String(split[0].dropFirst())
            let query = split.count > 1 ? String(split[1]) : ""
            
            inlineQueryTask = Task {
                do {
                    // Debounce typing
                    try await Task.sleep(nanoseconds: 300_000_000)
                    
                    self.isInlineQueryLoading = true
                    let botUserId = try await telegram.resolveBot(username: botUsername)
                    let results = try await telegram.getInlineQueryResults(botUserId: botUserId, chatId: self.chatId, query: query)
                    
                    if !Task.isCancelled {
                        self.inlineResults = results.results
                        self.currentInlineQueryId = results.inlineQueryId
                        self.currentInlineBotUserId = botUserId
                        self.currentInlineBotUsername = botUsername
                        self.currentInlineQuery = query
                        self.isInlineQueryLoading = false
                    }
                } catch {
                    if !Task.isCancelled {
                        self.inlineResults = []
                        self.isInlineQueryLoading = false
                    }
                }
            }
            return
        }
        
        self.inlineResults = []
        self.isInlineQueryLoading = false
        self.currentInlineBotUsername = nil
    }
    
    func sendInlineResult(_ result: AppInlineQueryResult) async {
        guard let queryId = currentInlineQueryId, let botUserId = currentInlineBotUserId else { return }
        do {
            try await telegram.sendInlineQueryResultMessage(chatId: chatId, botUserId: botUserId, queryId: queryId, resultId: result.id)
            // Successfully sent, clear state
            self.inlineResults = []
            self.currentInlineBotUsername = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

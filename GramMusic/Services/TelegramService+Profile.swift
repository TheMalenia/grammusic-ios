import Foundation
import SwiftData

/// Profile Music, offline gating, reporting and chat messaging for `TelegramService`.
///
/// Split out of `TelegramService.swift`. Profile Music is the one *editable* smart playlist —
/// its writes go back to Telegram and the server owns the ordering, so everything here is a
/// thin, offline-guarded wrapper over the backend plus the local mirror reconciliation.
@MainActor
extension TelegramService {

    // MARK: - Profile Music (the songs on the user's own Telegram profile)

    /// Pull the user's Telegram profile audio and mirror it into the Profile Music smart playlist.
    /// The server owns the list, so this is a one-way refresh; failures (offline/transient) leave
    /// the existing mirror in place rather than surfacing an error.
    func syncProfileAudio() async {
        guard let context = modelContext else { return }
        do {
            let tracks = try await allOwnProfileAudio()
            PlaylistService(context: context).replaceProfileAudio(with: tracks)
            refreshProfileIds()
        } catch {
            log.error("Profile audio sync failed: \(error.localizedDescription)")
        }
    }

    /// Whether a track is currently on the user's Telegram profile (mirrored locally).
    func isProfileAudio(_ track: AudioTrack) -> Bool {
        profileIds.contains(track.remoteUniqueId)
    }

    /// Not currently connected to Telegram, so streaming un-downloaded tracks and profile writes
    /// won't work. `.updating` already has a live connection (handshake done, just syncing), so it
    /// counts as connected; only `.connecting`/`.waitingForNetwork` are "offline". This is the
    /// *immediate* value — used to gate writes the instant the user acts.
    var isOffline: Bool { connectionState != .ready && connectionState != .updating }

    /// Recompute `isOfflineStable` (declared on the main type — extensions can't store).
    func refreshOfflineStable() {
        offlineDebounce?.cancel()
        guard isOffline else { isOfflineStable = false; return }
        offlineDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled, self.isOffline else { return }
            self.isOfflineStable = true
        }
    }

    /// Add a track to the user's Telegram profile, then re-sync the mirror.
    func addToProfile(_ track: AudioTrack) async {
        guard !isOffline else { lastError = "You're offline. Connect to the internet to update your profile."; return }
        await run { try await self.backend.addProfileAudio(track) }
        await syncProfileAudio()
    }

    /// Remove a track from the user's Telegram profile, then re-sync the mirror.
    func removeFromProfile(_ track: AudioTrack) async {
        guard !isOffline else { lastError = "You're offline. Connect to the internet to update your profile."; return }
        await run { try await self.backend.removeProfileAudio(track) }
        await syncProfileAudio()
    }

    /// Drag-to-reorder within the Profile Music playlist (SwiftUI `onMove` semantics). Optimistically
    /// reorders the local mirror, pushes the new position to Telegram, then re-syncs to reconcile.
    func moveProfileAudio(from source: IndexSet, to destination: Int) async {
        guard !isOffline else { lastError = "You're offline. Connect to the internet to update your profile."; return }
        guard let context = modelContext,
              let profile = PlaylistService(context: context).existingProfile(),
              let movedIndex = source.first else { return }
        var ordered = profile.orderedTracks
        let movedRef = ordered[movedIndex]
        let moved = movedRef.audioTrack
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, ref) in ordered.enumerated() { ref.order = index }
        try? context.save()
        // The track now sitting directly before the moved one is the server "after" anchor (nil = top).
        let newIndex = ordered.firstIndex { $0.id == movedRef.id }
        let after = (newIndex.map { $0 > 0 ? ordered[$0 - 1].audioTrack : nil }) ?? nil
        await run { try await self.backend.reorderProfileAudio(moved, after: after) }
        await syncProfileAudio()
    }

    /// Report a chat or specific messages in a chat.
    func reportChat(chatId: Int64, messageIds: [Int64]? = nil, optionId: Data? = nil, text: String? = nil) async throws -> TelegramReportResult {
        return try await backend.reportChat(chatId: chatId, messageIds: messageIds, optionId: optionId, text: text)
    }

    /// Determines if a track (or its chat) can be reported.
    func isReportable(track: AudioTrack) -> Bool {
        if track.chatId == 0 || track.messageId <= 0 { return false }
        if let chat = chats.first(where: { $0.id == track.chatId }) {
            return isReportable(chat: chat)
        }
        return true
    }

    /// Whether this chat can be reported to Telegram.
    ///
    /// **Reporting and blocking are different questions** — see `moderationAction(for:)` for the
    /// other one. This used to exclude private chats and bots as well, which left an abusive
    /// *person* reportable nowhere: exactly the case App Store guideline 1.2 asks apps to cover,
    /// and exactly the case Telegram's `reportChat` does accept. Only Saved Messages is excluded
    /// now, because it is the user's own chat and there is nobody to report.
    func isReportable(chat: TelegramChat) -> Bool {
        chat.kind != .savedMessages
    }

    // MARK: - Chat Messaging

    func chatHistory(in chatId: Int64, limit: Int, fromMessageId: Int64) async throws -> [ChatMessage] {
        return try await backend.chatHistory(in: chatId, limit: limit, fromMessageId: fromMessageId)
    }

    func sendTextMessage(to chatId: Int64, text: String) async {
        await run { try await self.backend.sendTextMessage(to: chatId, text: text) }
    }

    func sendAudioMessage(to chatId: Int64, track: AudioTrack, caption: String?) async {
        await run { try await self.backend.sendAudioMessage(to: chatId, track: track, caption: caption) }
    }

    func sendBotCallbackQuery(chatId: Int64, messageId: Int64, payload: Data) async {
        await run { try await self.backend.sendBotCallbackQuery(chatId: chatId, messageId: messageId, payload: payload) }
    }

    /// Main-actor isolated (rather than `nonisolated`) because `backend` is swappable for demo
    /// mode — reading it off the actor would be a race. Callers are all main-actor views.
    func messageUpdates(for chatId: Int64) -> AsyncStream<MessageUpdate> {
        backend.messageUpdates(for: chatId)
    }

    func resolveBot(username: String) async throws -> Int64 {
        try await backend.resolveBot(username: username)
    }
    
    func getInlineQueryResults(botUserId: Int64, chatId: Int64, query: String, offset: String = "") async throws -> AppInlineQueryResults {
        try await backend.getInlineQueryResults(botUserId: botUserId, chatId: chatId, query: query, offset: offset)
    }
    
    func sendInlineQueryResultMessage(chatId: Int64, botUserId: Int64, queryId: Int64, resultId: String) async throws {
        try await backend.sendInlineQueryResultMessage(chatId: chatId, botUserId: botUserId, queryId: queryId, resultId: resultId)
    }

}

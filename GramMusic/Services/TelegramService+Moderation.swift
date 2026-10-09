import Foundation

/// Blocking and reporting — the moderation half of guideline 1.2.
///
/// Reporting already existed (`reportChat`, `NReportSheet`). Blocking did not, and App Review
/// rejected the app for it: an app that shows content other people produced must let the user
/// block the source, and blocking must **remove that content from their feed instantly** — not
/// at the next sync, and not only on Telegram's side where a cached chat list would keep serving
/// it for hours.
///
/// **There are two actions, because a channel and a person are not the same problem.** Telegram
/// agrees: TDLib can only block *users and supergroups*, so there is no single call covering both.
/// - **Leave** (`leave(chat:)`) — for a channel or group. You stop following a broadcast source;
///   you do not "block" it. Leaves on Telegram *and* hides it locally so it goes immediately
///   rather than at the next chat-list sync. Reversible: rejoin on Telegram, unhide in the import
///   screen.
/// - **Block** (`block(chat:)`) — for a person or a bot, which is what guideline 1.2 is actually
///   about. Blocks the sender on Telegram and records it in the per-account local block list.
///
/// Both share the same app-side half, and that half is the one that must never fail: the local
/// list is authoritative for what the app displays, applied at the funnels every list flows
/// through *and* purged eagerly from the caches and the play queue, so the effect is immediate even
/// offline. The Telegram half runs at `FailureSurface.log` and is allowed to fail — an action that
/// silently did nothing because the link was down is the worst possible outcome here.
@MainActor
extension TelegramService {

    // MARK: - Reading

    func isBlocked(chatId: Int64) -> Bool { blockedChatIds.contains(chatId) }

    func isBlocked(_ track: AudioTrack) -> Bool { blockedChatIds.contains(track.chatId) }

    /// Strip blocked sources out of a track list. The single helper every surface calls, so a new
    /// list screen inherits blocking by using it rather than by remembering to.
    func visible(_ tracks: [AudioTrack]) -> [AudioTrack] {
        return tracks.filter { !blockedChatIds.contains($0.chatId) && !hiddenTracks.ids.contains($0.remoteUniqueId) }
    }

    func isHidden(_ track: AudioTrack) -> Bool { hiddenTracks.ids.contains(track.remoteUniqueId) }

    func hideTracks(_ tracks: [AudioTrack]) {
        hiddenTracks.hide(tracks)
        onTracksHidden?(Set(tracks.map(\.remoteUniqueId)))
    }

    func unhideTrack(_ track: AudioTrack) { hiddenTracks.unhide(track.remoteUniqueId) }

    func unhideTracks(_ tracks: [AudioTrack]) {
        hiddenTracks.unhide(Set(tracks.map(\.remoteUniqueId)))
    }

    /// The blocked senders, titles included. Nothing in the UI lists these today; it exists so the
    /// persisted list round-trips with names intact, and so a future "blocked" screen has
    /// something to render — a blocked chat is filtered out of `chats`, so by then there would be
    /// nothing left to look the name up in.
    var blockedChatEntries: [BlockedChatEntry] {
        blockedChatIds
            .map { id in
                BlockedChatEntry(id: id, title: blockedTitles[id] ?? "Chat \(id)")
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Writing

    /// What "I'm done with this source" means for a given chat.
    ///
    /// Three cases, and collapsing them is how the option disappeared entirely for the chats that
    /// most need it: Block used to be nested inside the `isReportable(chat:)` guard, and that
    /// predicate *excludes* private chats and bots — so the one kind of source guideline 1.2 is
    /// actually about offered nothing at all. Reportability and blockability are different
    /// questions and must be asked separately.
    enum ChatModeration: Equatable {
        /// A channel or group: you stop following a broadcast, you do not block it — and TDLib
        /// cannot block it anyway.
        case leave
        /// A person or bot: the guideline-1.2 case.
        case block
        /// Saved Messages — the user's own chat. There is nobody to block and nothing to leave;
        /// Hide is the only sensible action.
        case none
    }

    func moderationAction(for chat: TelegramChat) -> ChatModeration {
        switch chat.kind {
        case .channel, .group: return .leave
        case .savedMessages: return .none
        case .privateChat, .bot, .secret, .unknown: return .block
        }
    }

    /// Kept as the one-line question surfaces ask when they only need to pick a verb.
    func isLeaveTarget(_ chat: TelegramChat) -> Bool { moderationAction(for: chat) == .leave }

    /// Block the person behind a profile-music playlist.
    func block(profile: UserProfilePlaylist) async {
        await block(chat: TelegramChat(id: profile.chatId == 0 ? profile.userId : profile.chatId,
                                       title: profile.userName,
                                       kind: .privateChat,
                                       userId: profile.userId))
    }

    /// Block a person or bot: hide everything from them immediately, then tell Telegram.
    ///
    /// The local half is synchronous on purpose — the UI must not show blocked content for the
    /// duration of a network round-trip.
    func block(chat: TelegramChat) async {
        guard !blockedChatIds.contains(chat.id) else { return }
        blockedChatIds.insert(chat.id)
        blockedTitles[chat.id] = chat.title
        persistBlockList()
        purgeBlockedContent()

        await run(surface: .log) {
            try await self.backend.setSenderBlocked(chatId: chat.id, userId: chat.userId, blocked: true)
        }
    }

    /// Leave a channel or group, and take it out of the Library at once.
    ///
    /// Leaving alone would drop it on the *next* chat-list refresh, which is rate-limited to
    /// minutes — so the user taps Leave and watches the channel sit there. Hiding locally closes
    /// that gap. It is not added to the block list: someone who rejoins the channel on Telegram
    /// should get it back by unhiding, not find it permanently suppressed by a list with no UI.
    func leave(chat: TelegramChat) async {
        onChatLeft?(chat.id)          // hide locally (wired to ImportStore in GramMusicApp)
        chats.removeAll { $0.id == chat.id }
        purge(chatIds: [chat.id])

        await run(surface: .log) { try await self.backend.leaveChat(chatId: chat.id) }
    }

    /// Unblock a chat. Its content reappears on the next sync — nothing was deleted, only hidden,
    /// which is why `visible(_:)` filters rather than the caches dropping rows permanently.
    func unblock(chatId: Int64) async {
        guard blockedChatIds.contains(chatId) else { return }
        let userId = chats.first(where: { $0.id == chatId })?.userId
        blockedChatIds.remove(chatId)
        blockedTitles[chatId] = nil
        persistBlockList()

        // Only the sender block is reversible from here. A channel the user *left* is not
        // rejoined behind their back — that is a membership change they should make themselves.
        await run(surface: .log) {
            try await self.backend.setSenderBlocked(chatId: chatId, userId: userId, blocked: false)
        }
        await refreshChats(force: true)
    }

    // MARK: - Reconciling with Telegram

    /// Make the local block list agree with Telegram's.
    ///
    /// **Telegram is the source of truth for blocking**, the same way it is for Profile Music.
    /// Without this the local list could only ever grow: block someone here, unblock them *in
    /// Telegram*, and they stayed hidden in GramMusic forever — across relaunches, and with no
    /// in-app way back since there is no blocked-sources screen. Mirroring is deliberately
    /// two-way: a sender blocked in Telegram is someone the user does not want to hear from, so
    /// their music should not be playing here either.
    ///
    /// `leave` is *not* reconciled this way — leaving a channel is a membership change, and the
    /// local hide that accompanies it lives in `ImportStore`, undone in the import screen.
    func syncBlockList() async {
        var remote: Set<Int64> = []
        let ok = await run(surface: .log) { remote = try await self.backend.blockedSenderIds() }
        // A failed fetch must not be read as "Telegram blocks nobody" — that would silently clear
        // every block the user made.
        guard ok else { return }
        guard remote != blockedChatIds else { return }

        for id in blockedChatIds.subtracting(remote) { blockedTitles[id] = nil }
        blockedChatIds = remote
        persistBlockList()
        purgeBlockedContent()
    }

    /// Apply a live block/unblock that happened in Telegram while the app was open.
    func applyBlockListChange(chatId: Int64, isBlocked: Bool) {
        guard blockedChatIds.contains(chatId) != isBlocked else { return }
        if isBlocked {
            blockedChatIds.insert(chatId)
            blockedTitles[chatId] = chats.first { $0.id == chatId }?.title
            persistBlockList()
            purgeBlockedContent()
        } else {
            blockedChatIds.remove(chatId)
            blockedTitles[chatId] = nil
            persistBlockList()
            Task { await refreshChats(force: true) }
        }
    }

    // MARK: - Instant removal

    /// Drop blocked content from everything already in memory.
    ///
    /// Filtering at the funnels alone is not enough for "instantly": `recentlyPlayed`, the listing
    /// caches and the play queue are *state*, not derived views, so a blocked chat would keep
    /// showing up in the Home shelves and keep playing until something happened to rebuild them.
    func purgeBlockedContent() {
        purge(chatIds: blockedChatIds)
    }

    /// Drop a set of chats' content from everything already in memory. Shared by block and leave.
    func purge(chatIds: Set<Int64>) {
        guard !chatIds.isEmpty else { return }

        chats.removeAll { chatIds.contains($0.id) }
        recentlyPlayed.removeAll { chatIds.contains($0.chatId) }
        persistRecentlyPlayed()

        for id in chatIds { chatAudioCache[id] = nil }
        for (artist, tracks) in artistAudioCache {
            let kept = tracks.filter { !chatIds.contains($0.chatId) }
            if kept.count != tracks.count { artistAudioCache[artist] = kept }
        }
        persistListingCaches()

        // Removing the source of the track that is playing must stop it playing.
        onContentBlocked?(chatIds)
    }

    // MARK: - Persistence

    func loadBlockList() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: StorageKeys.blockedChats),
           let stored = try? JSONDecoder().decode(StoredBlockList.self, from: data) {
            blockedChatIds = Set(stored.entries.map(\.id))
            blockedTitles = Dictionary(uniqueKeysWithValues: stored.entries.map { ($0.id, $0.title) })
        }
    }

    func persistBlockList() {
        let stored = StoredBlockList(entries: blockedChatEntries)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: StorageKeys.blockedChats)
    }
}

/// A blocked chat as the Settings list shows it. The title is stored alongside the id because a
/// blocked chat is filtered *out* of `chats`, so there is nothing left to look the name up in —
/// an unblock screen listing "Chat -100123456789" would be unusable.
struct BlockedChatEntry: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    let title: String
}

private struct StoredBlockList: Codable {
    let entries: [BlockedChatEntry]
}

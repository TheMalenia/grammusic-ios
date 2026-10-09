import XCTest
import AVFoundation
@testable import GramMusic

/// Blocking a source — the guideline 1.2 requirement App Review rejected the app for missing.
///
/// The bar Apple sets is not "a block list exists" but that blocking **removes the content from
/// the user's feed instantly**. So these tests are mostly about immediacy and about the block
/// surviving the things that could quietly undo it: a relaunch, a re-sync, autoplay wandering
/// back into a blocked chat, and the next person to sign in on the same device.
@MainActor
final class BlockListTests: XCTestCase {

    /// A service with no inherited state.
    ///
    /// `TelegramService` restores `recentlyPlayed` and the block list from `UserDefaults` in its
    /// initialiser, and the simulator's defaults outlive the test process — so without this, a
    /// second run sees the *previous* run's recently-played entries and the counts drift.
    private func makeService() -> TelegramService {
        for key in [StorageKeys.blockedChats, StorageKeys.recentlyPlayed] {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults(suiteName: "group.com.grammusic.app")?.removeObject(forKey: key)
        }
        return TelegramService(backend: MockTelegramBackend())
    }

    private func track(chat: Int64, id: String) -> AudioTrack {
        AudioTrack(chatId: chat, messageId: 1, fileId: 1, remoteUniqueId: id,
                   title: id, performer: "P", duration: 10)
    }

    // MARK: - Storage lifetime

    func test_blockList_isAccountData() {
        // One account's block list must not decide what the *next* person to sign in can see.
        XCTAssertTrue(StorageKeys.perAccount.contains(StorageKeys.blockedChats),
                      "a block list surviving sign-out leaks one account's moderation to another")
    }

    func test_termsAcceptance_isNotAccountData() {
        // The agreement is with whoever holds the phone; logging out of Telegram does not undo it.
        XCTAssertFalse(StorageKeys.perAccount.contains(StorageKeys.acceptedTermsVersion),
                       "re-prompting the terms on every sign-out is not what guideline 1.2 asks for")
    }

    // MARK: - Filtering

    func test_visible_dropsBlockedSources() async {
        let service = makeService()
        let tracks = [track(chat: 1, id: "a"), track(chat: 2, id: "b"), track(chat: 1, id: "c")]
        XCTAssertEqual(service.visible(tracks).count, 3)

        await service.block(chat: TelegramChat(id: 1, title: "Bad", kind: .channel))

        XCTAssertEqual(service.visible(tracks).map(\.remoteUniqueId), ["b"],
                       "every list funnels through visible(_:) — a blocked chat must not survive it")
    }

    func test_block_isImmediate_forRecentlyPlayed() async {
        let service = makeService()
        service.recordRecent(track(chat: 7, id: "x"))
        service.recordRecent(track(chat: 8, id: "y"))
        XCTAssertEqual(service.recentlyPlayed.count, 2)

        await service.block(chat: TelegramChat(id: 7, title: "Bad", kind: .channel))

        // Not "on the next sync": the Home shelf reads this array directly.
        XCTAssertEqual(service.recentlyPlayed.map(\.remoteUniqueId), ["y"],
                       "blocked content must leave the feed at the moment of blocking")
    }

    func test_block_survivesRelaunch() async {
        let service = makeService()
        await service.block(chat: TelegramChat(id: 42, title: "Bad Channel", kind: .channel))

        // A fresh service is what a relaunch produces.
        let relaunched = TelegramService(backend: MockTelegramBackend())
        XCTAssertTrue(relaunched.isBlocked(chatId: 42))
        XCTAssertEqual(relaunched.blockedChatEntries.first?.title, "Bad Channel",
                       "the title is stored with the id because a blocked chat is filtered out of `chats`")
    }

    func test_autoplay_neverReturnsToABlockedSource() async {
        let service = makeService()
        service.recordRecent(track(chat: 3, id: "keep"))
        service.recordRecent(track(chat: 4, id: "blocked"))

        await service.block(chat: TelegramChat(id: 4, title: "Bad", kind: .channel))

        let candidates = service.autoplayCandidates(seed: nil, excluding: [])
        XCTAssertFalse(candidates.contains { $0.chatId == 4 },
                       "'Keep playing' re-introducing blocked content is the app undoing the user's decision")
    }

    // MARK: - The Telegram half

    func test_channel_isLeft_notBlocked() async {
        // TDLib can only block users and supergroups, and you don't "block" a broadcast you
        // follow — you stop following it.
        let backend = MockTelegramBackend()
        UserDefaults.standard.removeObject(forKey: StorageKeys.blockedChats)
        let service = TelegramService(backend: backend)
        let channel = TelegramChat(id: 9, title: "Channel", kind: .channel)

        XCTAssertTrue(service.isLeaveTarget(channel))
        await service.leave(chat: channel)

        let left = await backend.leftChatIds
        let blocked = await backend.blockedSenderChatIds
        XCTAssertTrue(left.contains(9))
        XCTAssertFalse(blocked.contains(9))
    }

    func test_leaving_hidesTheChatLocally() async {
        // Leaving alone would drop the channel on the *next* chat-list refresh, which is rate
        // limited to minutes — so the user taps Leave and watches it sit in the Library.
        let service = makeService()
        var hidden: [Int64] = []
        service.onChatLeft = { hidden.append($0) }

        await service.leave(chat: TelegramChat(id: 9, title: "Channel", kind: .channel))

        XCTAssertEqual(hidden, [9])
    }

    func test_leaving_doesNotAddToTheBlockList() async {
        // Someone who rejoins the channel on Telegram must get it back by unhiding, not find it
        // permanently suppressed by a list with no UI to clear it.
        let service = makeService()
        await service.leave(chat: TelegramChat(id: 9, title: "Channel", kind: .channel))
        XCTAssertFalse(service.isBlocked(chatId: 9))
    }

    func test_peopleAndBots_areBlockedNotLeft() async {
        let service = makeService()
        for kind in [TelegramChat.Kind.privateChat, .bot] {
            XCTAssertFalse(service.isLeaveTarget(TelegramChat(id: 1, title: "x", kind: kind)),
                           "\(kind) is a person to block, not a broadcast to leave")
        }
        for kind in [TelegramChat.Kind.channel, .group] {
            XCTAssertTrue(service.isLeaveTarget(TelegramChat(id: 1, title: "x", kind: kind)))
        }
    }

    func test_privateChat_blocksTheSender() async {
        let backend = MockTelegramBackend()
        UserDefaults.standard.removeObject(forKey: StorageKeys.blockedChats)
        let service = TelegramService(backend: backend)

        await service.block(chat: TelegramChat(id: 11, title: "Someone", kind: .privateChat, userId: 500))

        let blocked = await backend.blockedSenderChatIds
        let left = await backend.leftChatIds
        XCTAssertTrue(blocked.contains(11))
        XCTAssertFalse(left.contains(11), "blocking a person is not leaving a channel")
    }

    func test_localBlockStands_evenWhenTelegramCannotBeReached() async {
        // The whole point of the local list: a block must not silently do nothing offline.
        let service = makeService()
        await service.block(chat: TelegramChat(id: 77, title: "Bad", kind: .channel))
        XCTAssertTrue(service.isBlocked(chatId: 77))
    }

    func test_unblock_restoresVisibility() async {
        let service = makeService()
        let tracks = [track(chat: 5, id: "a")]
        await service.block(chat: TelegramChat(id: 5, title: "Bad", kind: .privateChat, userId: 1))
        XCTAssertTrue(service.visible(tracks).isEmpty)

        await service.unblock(chatId: 5)

        XCTAssertEqual(service.visible(tracks).count, 1,
                       "nothing is deleted by a block, only hidden — so unblocking restores it")
    }
}

/// Blocking the source of the track that is *playing*.
///
/// `removeFromQueue(at:)` deliberately refuses to remove the current entry, which is right for a
/// user reordering their queue and exactly wrong here — blocking a source and having its song keep
/// playing is the one outcome that makes the feature look broken to a reviewer holding the phone.
@MainActor
final class BlockedQueuePurgeTests: XCTestCase {

    private func track(chat: Int64, id: String) -> AudioTrack {
        AudioTrack(chatId: chat, messageId: 1, fileId: 1, remoteUniqueId: id,
                   title: id, performer: "P", duration: 100)
    }

    private func engine() -> PlayerEngine {
        PlayerEngine(
            fileProvider: { _ in URL(fileURLWithPath: "/dev/null") },
            itemProvider: { _ in AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")) }
        )
    }

    func test_blockedTracks_leaveTheQueue() async {
        let player = engine()
        player.play(tracks: [track(chat: 1, id: "a"), track(chat: 2, id: "b"), track(chat: 1, id: "c")], startAt: 0)
        try? await Task.sleep(for: .milliseconds(150))

        player.removeBlockedSources([1])

        XCTAssertEqual(player.queue.map(\.remoteUniqueId), ["b"])
    }

    func test_blockingTheCurrentTrack_movesOffIt() async {
        let player = engine()
        player.play(tracks: [track(chat: 1, id: "playing"), track(chat: 2, id: "next")], startAt: 0)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(player.current?.remoteUniqueId, "playing")

        player.removeBlockedSources([1])
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(player.current?.remoteUniqueId, "next",
                       "the blocked track must not keep playing")
    }

    func test_blockingEverythingInTheQueue_stopsPlayback() async {
        let player = engine()
        player.play(tracks: [track(chat: 1, id: "a"), track(chat: 1, id: "b")], startAt: 0)
        try? await Task.sleep(for: .milliseconds(150))

        player.removeBlockedSources([1])
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(player.current, "nothing playable is left, so the mini-player must go away")
        XCTAssertTrue(player.queue.isEmpty)
    }

    func test_unrelatedBlock_leavesTheQueueAlone() async {
        let player = engine()
        player.play(tracks: [track(chat: 1, id: "a"), track(chat: 1, id: "b")], startAt: 0)
        try? await Task.sleep(for: .milliseconds(150))

        player.removeBlockedSources([99])

        XCTAssertEqual(player.queue.count, 2)
    }
}

/// Telegram is the source of truth for blocking, and the app must follow it.
///
/// Without reconciliation the local list could only ever grow: block someone in GramMusic, unblock
/// them *in Telegram*, and they stayed hidden here forever — across relaunches, and with no in-app
/// way back now that there is no blocked-sources screen.
@MainActor
final class BlockListReconciliationTests: XCTestCase {

    private func makeService(_ backend: MockTelegramBackend) -> TelegramService {
        for key in [StorageKeys.blockedChats, StorageKeys.recentlyPlayed] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return TelegramService(backend: backend)
    }

    func test_unblockingInTelegram_reachesTheApp() async {
        let backend = MockTelegramBackend()
        let service = makeService(backend)
        await service.block(chat: TelegramChat(id: 5, title: "Someone", kind: .privateChat, userId: 5))
        XCTAssertTrue(service.isBlocked(chatId: 5))

        // The user unblocks them in Telegram itself.
        await backend.setBlockedSenders([])
        await service.syncBlockList()

        XCTAssertFalse(service.isBlocked(chatId: 5),
                       "an unblock made in Telegram must not leave the app hiding them forever")
    }

    func test_blockingInTelegram_isMirrored() async {
        let backend = MockTelegramBackend()
        let service = makeService(backend)
        await backend.setBlockedSenders([99])

        await service.syncBlockList()

        XCTAssertTrue(service.isBlocked(chatId: 99),
                      "someone the user blocked on Telegram should not be playing here either")
    }

    func test_liveUnblock_appliesWithoutARelaunch() async {
        let service = makeService(MockTelegramBackend())
        await service.block(chat: TelegramChat(id: 7, title: "Someone", kind: .privateChat, userId: 7))

        service.applyBlockListChange(chatId: 7, isBlocked: false)

        XCTAssertFalse(service.isBlocked(chatId: 7))
    }

    func test_aFailedFetch_doesNotClearTheBlockList() async {
        // "Telegram returned nothing" must never be read as "Telegram blocks nobody" — that would
        // silently undo every block the user made the moment the network hiccuped.
        let backend = MockTelegramBackend()
        let service = makeService(backend)
        await service.block(chat: TelegramChat(id: 3, title: "Someone", kind: .privateChat, userId: 3))
        await backend.setBlockListFetchFails(true)

        await service.syncBlockList()

        XCTAssertTrue(service.isBlocked(chatId: 3),
                      "a dropped request is not evidence that the user unblocked anyone")
    }
}

import XCTest
@testable import GramMusic

/// `AudioSearch` is the whole matching/ranking engine behind every search surface, and it is
/// pure — no Telegram, no network, no SwiftData — so the behaviours the UI depends on are pinned
/// here rather than discovered by scrolling a result list.
final class AudioSearchTests: XCTestCase {

    private func track(_ title: String,
                       performer: String = "",
                       chatId: Int64 = 1,
                       messageId: Int64 = 1,
                       unique: String = "u",
                       fileId: Int = 0,
                       artwork: Data? = nil,
                       date: Int? = nil,
                       fileName: String? = nil) -> AudioTrack {
        AudioTrack(chatId: chatId, messageId: messageId, fileId: fileId, remoteUniqueId: unique,
                   title: title, performer: performer, duration: 120, date: date,
                   fileName: fileName, artworkData: artwork)
    }

    // MARK: Folding

    func test_fold_isCaseDiacriticAndPunctuationInsensitive() {
        XCTAssertEqual(AudioSearch.fold("Beyoncé — Halo!"), "beyonce halo")
        XCTAssertEqual(AudioSearch.fold("  Get   Lucky  "), "get lucky")
    }

    /// Telegram audio is full of Arabic-vs-Persian spellings of the same word; typing one must
    /// find the other, or half a Persian library is unsearchable.
    func test_fold_unifiesArabicAndPersianVariants() {
        XCTAssertEqual(AudioSearch.fold("يك"), AudioSearch.fold("یک"))
        XCTAssertEqual(AudioSearch.fold("۱۲۳"), "123")
    }

    func test_matches_requiresEveryToken() {
        XCTAssertTrue(AudioSearch.matches("Daft Punk — Get Lucky", query: "daft lucky"))
        XCTAssertFalse(AudioSearch.matches("Daft Punk — Get Lucky", query: "daft stardust"))
        // An empty query filters nothing out.
        XCTAssertTrue(AudioSearch.matches("anything", query: "   "))
    }

    // MARK: De-duplication — the bug the user reported

    /// One song posted in two chats is two *messages* but one piece of audio, and Telegram's
    /// message search returns both. It must appear once.
    func test_rank_collapsesTheSameAudioPostedInSeveralChats() {
        let a = track("Halo", performer: "Beyonce", chatId: 10, messageId: 1, unique: "same")
        let b = track("Halo", performer: "Beyonce", chatId: 77, messageId: 9, unique: "same")

        XCTAssertEqual(AudioSearch.rank([a, b], query: "halo").count, 1)
    }

    /// Distinct audio must never collapse, including the profile-audio case where there is no
    /// source message but the remote id still differs.
    func test_rank_keepsDistinctAudio() {
        let a = track("Halo", chatId: 0, messageId: 0, unique: "one")
        let b = track("Halo", chatId: 0, messageId: 0, unique: "two")

        XCTAssertEqual(AudioSearch.rank([a, b], query: "halo").count, 2)
    }

    /// Of two copies of one song, the survivor is the one that can still be played, added to a
    /// profile and reported — i.e. the one that kept its source message and artwork.
    func test_deduped_keepsTheRichestCopy() {
        let poor = track("Halo", chatId: 0, messageId: 0, unique: "same")
        let rich = track("Halo", performer: "Beyonce", chatId: 5, messageId: 6, unique: "same",
                         artwork: Data([1]))

        XCTAssertEqual(AudioSearch.deduped([poor, rich]).first?.chatId, 5)
        XCTAssertEqual(AudioSearch.deduped([rich, poor]).first?.chatId, 5)
    }

    // MARK: Ranking

    /// Telegram orders by message date, which buries the song the user literally named under
    /// whatever was posted most recently.
    func test_rank_putsTheExactTitleFirst() {
        let newest = track("Halo Remix (Extended)", unique: "a", date: 900)
        let exact = track("Halo", unique: "b", date: 100)

        XCTAssertEqual(AudioSearch.rank([newest, exact], query: "Halo").first?.remoteUniqueId, "b")
    }

    func test_rank_prefersTitleOverPerformerMatches() {
        let byPerformer = track("Something Else", performer: "Halo", unique: "a")
        let byTitle = track("Halo Nights", performer: "Someone", unique: "b")

        XCTAssertEqual(AudioSearch.rank([byPerformer, byTitle], query: "halo").first?.remoteUniqueId, "b")
    }

    /// Every typed word has to land somewhere, so a second word narrows instead of widening.
    func test_rank_dropsTracksMissingAToken() {
        let hit = track("Get Lucky", performer: "Daft Punk", unique: "a")
        let miss = track("Get Down", performer: "Someone", unique: "b")

        let results = AudioSearch.rank([hit, miss], query: "daft get")
        XCTAssertEqual(results.map(\.remoteUniqueId), ["a"])
    }

    /// Untagged Telegram audio has no title at all — the file name is what the row shows, so it
    /// has to be searchable too.
    func test_rank_matchesOnFileNameWhenThereIsNoTitle() {
        let untagged = track("", unique: "a", fileName: "Hendooneh - هندونه.mp3")
        XCTAssertEqual(AudioSearch.rank([untagged], query: "hendooneh").count, 1)
        XCTAssertEqual(AudioSearch.rank([untagged], query: "هندونه").count, 1)
    }

    func test_rank_emptyQueryReturnsEverythingDeduped() {
        let a = track("One", unique: "same")
        let b = track("One", unique: "same")
        XCTAssertEqual(AudioSearch.rank([a, b], query: "  ").count, 1)
    }

    // MARK: Artists

    func test_artists_areDistinctAndOrderedByMatchQuality() {
        let tracks = [
            track("A", performer: "Daft Punk Tribute", unique: "1"),
            track("B", performer: "Daft Punk", unique: "2"),
            track("C", performer: "daft punk", unique: "3"),
            track("D", performer: "Someone", unique: "4")
        ]
        let artists = AudioSearch.artists(in: tracks, query: "daft punk")
        XCTAssertEqual(artists.count, 2)
        XCTAssertEqual(artists.first, "Daft Punk")
    }

    func test_artists_ignoreOneCharacterPerformers() {
        XCTAssertTrue(AudioSearch.artists(in: [track("A", performer: "X", unique: "1")], query: "x").isEmpty)
    }
}

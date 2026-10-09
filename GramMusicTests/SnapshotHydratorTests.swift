import XCTest
@testable import GramMusic

/// Deciding *what* to fetch is the expensive decision, so it's a pure function and tested here
/// with no backend. The fetching itself is a thin loop over this plan.
final class SnapshotHydratorTests: XCTestCase {

    private func track(_ id: String, performer: String = "Artist") -> AudioTrack {
        AudioTrack(chatId: 0, messageId: 0, fileId: 1, remoteUniqueId: id, remoteFileId: "r-\(id)",
                   title: "Song \(id)", performer: performer, duration: 100)
    }

    private func snapshot() -> LibrarySnapshot {
        var s = LibrarySnapshot()
        s.artists = ["Radiohead", "Björk"]
        s.chats = [.init(id: 10, title: "LoFi Beats HQ"), .init(id: 20, title: "Persian Classics")]
        s.tracksByArtist = ["Radiohead": [track("r1", performer: "Radiohead")]]
        s.tracksByChat = [10: [track("l1")]]   // chat 20 is known but uncached
        return s
    }

    func test_cachedChat_isNotFetchedAgain() {
        let recipe = PlaylistRecipe(name: "X", chats: ["LoFi Beats HQ"])

        let plan = SnapshotHydrator.plan(for: recipe, given: snapshot())

        XCTAssertTrue(plan.chatsToFetch.isEmpty)
        XCTAssertTrue(plan.isEmpty)
    }

    /// The gap this whole stage exists to close: a chat the user has never opened.
    func test_uncachedChat_isScheduledForFetch() {
        let recipe = PlaylistRecipe(name: "X", chats: ["persian classics"])

        let plan = SnapshotHydrator.plan(for: recipe, given: snapshot())

        XCTAssertEqual(plan.chatsToFetch.map(\.id), [20])
    }

    func test_followedArtistWithNoCachedTracks_goesToSearch() {
        let recipe = PlaylistRecipe(name: "X", artists: ["Björk"])

        let plan = SnapshotHydrator.plan(for: recipe, given: snapshot())

        XCTAssertEqual(plan.artistsToSearch, ["Björk"])
    }

    /// An artist the user doesn't follow is reachable through search — that's what lets the
    /// assistant answer for any performer in their Telegram, not just followed ones.
    func test_unfollowedArtist_goesToSearch() {
        let recipe = PlaylistRecipe(name: "X", artists: ["Boards of Canada"])

        let plan = SnapshotHydrator.plan(for: recipe, given: snapshot())

        XCTAssertEqual(plan.artistsToSearch, ["Boards of Canada"])
    }

    func test_artistAlreadyCached_isNotSearched() {
        let recipe = PlaylistRecipe(name: "X", artists: ["radiohead"])

        let plan = SnapshotHydrator.plan(for: recipe, given: snapshot())

        XCTAssertTrue(plan.artistsToSearch.isEmpty)
    }

    func test_scopeOnlyRecipe_needsNoFetching() {
        let recipe = PlaylistRecipe(name: "X", scope: .favorites)

        XCTAssertTrue(SnapshotHydrator.plan(for: recipe, given: snapshot()).isEmpty)
    }

    func test_mixedRequest_plansBothHalves() {
        let recipe = PlaylistRecipe(name: "X", artists: ["Aphex Twin"], chats: ["Persian Classics"])

        let plan = SnapshotHydrator.plan(for: recipe, given: snapshot())

        XCTAssertEqual(plan.artistsToSearch, ["Aphex Twin"])
        XCTAssertEqual(plan.chatsToFetch.map(\.id), [20])
    }
}

import XCTest
@testable import GramMusic

/// `HeuristicComposer` is the path that runs offline, out of quota, and on every device without a
/// local model — so it is tested as a real feature, not as a stub.
final class HeuristicComposerTests: XCTestCase {

    private let composer = HeuristicComposer()

    private let roster = ComposerRoster(
        artists: ["Radiohead", "Björk", "Aphex Twin", "Sigur Rós"],
        chats: ["LoFi Beats HQ", "Persian Classics", "Saved Messages"]
    )

    private func compose(_ text: String) async throws -> ComposerReply {
        try await composer.compose(text, roster: roster)
    }

    // MARK: - Name scanning

    func test_findsArtistAndChat_inACasualSentence() async throws {
        let reply = try await compose("make me something chill from radiohead and lofi beats hq")

        let recipe = try XCTUnwrap(reply.recipe)
        XCTAssertEqual(recipe.artists, ["Radiohead"])
        XCTAssertEqual(recipe.chats, ["LoFi Beats HQ"])
        XCTAssertEqual(recipe.moods, ["chill"])
    }

    func test_matchesAccentedNamesTypedPlainly() async throws {
        let reply = try await compose("some sigur ros please")

        XCTAssertEqual(try XCTUnwrap(reply.recipe).artists, ["Sigur Rós"])
    }

    /// A name outside the roster becomes a *search candidate*, not an invention: the residual
    /// words are handed on so `SnapshotHydrator` can put them through Telegram search. The
    /// invariant that matters is unchanged — it still cannot conjure tracks, and if search finds
    /// nothing `RecipeSelector` reports it unmatched.
    func test_namesOutsideTheRoster_becomeSearchCandidates() async throws {
        let reply = try await compose("play some taylor swift")

        let recipe = try XCTUnwrap(reply.recipe)
        XCTAssertEqual(recipe.artists, ["Taylor Swift"], "filler words stripped, name title-cased")
    }

    /// Filler with no name in it must not become a doomed search.
    func test_pureFiller_asksForMoreRatherThanSearching() async throws {
        let reply = try await compose("make me a playlist please")

        XCTAssertNil(reply.recipe)
    }

    /// A roster name still wins over the residual path.
    func test_rosterNameIsPreferredOverResidual() async throws {
        let reply = try await compose("play me some songs by radiohead")

        XCTAssertEqual(try XCTUnwrap(reply.recipe).artists, ["Radiohead"])
    }

    func test_emptyRequest_asksForMore() async throws {
        let reply = try await compose("   ")

        XCTAssertNil(reply.recipe)
    }

    // MARK: - Closed vocabularies

    func test_detectsCount() async throws {
        let reply = try await compose("15 tracks by aphex twin")

        XCTAssertEqual(try XCTUnwrap(reply.recipe).trackCount, 15)
    }

    func test_ignoresImplausibleNumbers_soAYearIsNotATrackCount() async throws {
        let reply = try await compose("radiohead stuff from 2019")

        XCTAssertEqual(try XCTUnwrap(reply.recipe).trackCount, PlaylistRecipe.Limits.defaultTracks)
    }

    func test_detectsScope() async throws {
        var reply = try await compose("my favourite radiohead songs")
        XCTAssertEqual(try XCTUnwrap(reply.recipe).scope, .favorites)

        reply = try await compose("downloaded björk")
        XCTAssertEqual(try XCTUnwrap(reply.recipe).scope, .downloaded)

        reply = try await compose("stuff I played recently")
        XCTAssertEqual(try XCTUnwrap(reply.recipe).scope, .recentlyPlayed)
    }

    func test_detectsSort() async throws {
        var reply = try await compose("most played radiohead")
        XCTAssertEqual(try XCTUnwrap(reply.recipe).sort, .mostPlayed)

        reply = try await compose("surprise me with aphex twin")
        XCTAssertEqual(try XCTUnwrap(reply.recipe).sort, .random)
    }

    /// A bare scope request carries no name, but is still a complete, actionable request.
    func test_scopeOnlyRequest_isEnoughToBuild() async throws {
        let reply = try await compose("something from my favourites")

        let recipe = try XCTUnwrap(reply.recipe)
        XCTAssertEqual(recipe.scope, .favorites)
        XCTAssertTrue(recipe.artists.isEmpty)
    }

    // MARK: - Naming

    func test_namesThePlaylistAfterWhatWasAsked() async throws {
        var reply = try await compose("chill radiohead")
        XCTAssertEqual(try XCTUnwrap(reply.recipe).name, "Chill Radiohead")

        reply = try await compose("radiohead and aphex twin")
        XCTAssertEqual(try XCTUnwrap(reply.recipe).name, "Radiohead & More")

        reply = try await compose("something from my favourites")
        XCTAssertEqual(try XCTUnwrap(reply.recipe).name, "From Your Favorites")
    }

    // MARK: - End to end, no model involved

    func test_requestToTracks_withoutAnyProvider() async throws {
        var snapshot = LibrarySnapshot()
        snapshot.artists = roster.artists
        snapshot.chats = [.init(id: 10, title: "LoFi Beats HQ")]
        snapshot.tracksByArtist = ["Radiohead": [
            AudioTrack(chatId: 0, messageId: 0, fileId: 1, remoteUniqueId: "r1",
                       title: "Song", performer: "Radiohead", duration: 100)
        ]]

        let reply = try await composer.compose("5 chill radiohead tracks", roster: snapshot.roster)
        let selection = RecipeSelector.select(try XCTUnwrap(reply.recipe), from: snapshot)

        XCTAssertEqual(selection.name, "Chill Radiohead")
        XCTAssertEqual(selection.tracks.map(\.remoteUniqueId), ["r1"])
        XCTAssertEqual(selection.matchedArtists, ["Radiohead"])
    }

    // MARK: - Roster hygiene

    func test_rosterCapping_keepsTheUsersOwnOrder() {
        let big = ComposerRoster(artists: (1...200).map { "Artist \($0)" }, chats: [])

        let capped = big.capped(artists: 3)

        XCTAssertEqual(capped.artists, ["Artist 1", "Artist 2", "Artist 3"])
    }
}

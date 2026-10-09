import XCTest
@testable import GramMusic

/// `RecipeSelector` decides what the user actually hears, so it is tested against literal
/// snapshots — no Telegram, no SwiftData, no model, no main actor.
final class RecipeSelectorTests: XCTestCase {

    private func track(_ id: String, performer: String = "Artist",
                       date: Int? = nil) -> AudioTrack {
        AudioTrack(chatId: 0, messageId: 0, fileId: 1, remoteUniqueId: id, remoteFileId: "r-\(id)",
                   title: "Song \(id)", performer: performer, duration: 100, date: date,
                   fileName: "\(id).mp3")
    }

    private func snapshot() -> LibrarySnapshot {
        var s = LibrarySnapshot()
        s.artists = ["Radiohead", "Björk", "Aphex Twin"]
        s.chats = [.init(id: 10, title: "LoFi Beats HQ"), .init(id: 20, title: "Persian Classics")]
        s.tracksByArtist = [
            "Radiohead": [track("r1", performer: "Radiohead"), track("r2", performer: "Radiohead")],
            "Björk": [track("b1", performer: "Björk")]
        ]
        s.tracksByChat = [
            10: [track("l1"), track("l2"), track("l3")],
            20: [track("p1")]
        ]
        s.favorites = [track("r1", performer: "Radiohead"), track("l1")]
        s.downloaded = [track("r2", performer: "Radiohead")]
        s.recentlyPlayed = [track("l3"), track("b1", performer: "Björk")]
        s.playCounts = ["l1": 9, "r1": 4, "r2": 1]
        return s
    }

    // MARK: - Matching

    func test_matchesArtistAndChat_byLooseName() {
        let recipe = PlaylistRecipe(name: "Mix", artists: ["radiohead"], chats: ["lofi beats"])

        let result = RecipeSelector.select(recipe, from: snapshot())

        XCTAssertEqual(result.matchedArtists, ["Radiohead"])
        XCTAssertEqual(result.matchedChats.map(\.title), ["LoFi Beats HQ"])
        XCTAssertTrue(result.unmatchedArtists.isEmpty)
        XCTAssertFalse(result.tracks.isEmpty)
    }

    func test_diacriticsAreIgnored_soBjorkFindsBjörk() {
        let recipe = PlaylistRecipe(name: "Mix", artists: ["bjork"])

        let result = RecipeSelector.select(recipe, from: snapshot())

        XCTAssertEqual(result.matchedArtists, ["Björk"])
    }

    /// The invariant that makes hallucination harmless: a name that doesn't exist yields no
    /// tracks and is reported, rather than being silently dropped.
    func test_unknownName_isReported_notSilentlyDropped() {
        let recipe = PlaylistRecipe(name: "Mix", artists: ["Taylor Swift"])

        let result = RecipeSelector.select(recipe, from: snapshot())

        XCTAssertEqual(result.unmatchedArtists, ["Taylor Swift"])
        XCTAssertTrue(result.tracks.isEmpty)
        XCTAssertTrue(result.missedEverything)
    }

    /// A request we couldn't honour must not degrade into "here's everything" — that reads as the
    /// request having been ignored.
    func test_allNamesUnknown_doesNotFallBackToWholeLibrary() {
        let recipe = PlaylistRecipe(name: "Mix", artists: ["Nobody"], chats: ["Nowhere"])

        let result = RecipeSelector.select(recipe, from: snapshot())

        XCTAssertTrue(result.tracks.isEmpty)
        XCTAssertEqual(result.unmatchedArtists, ["Nobody"])
        XCTAssertEqual(result.unmatchedChats, ["Nowhere"])
    }

    func test_noNamesAtAll_usesScope() {
        let recipe = PlaylistRecipe(name: "Faves", scope: .favorites)

        let result = RecipeSelector.select(recipe, from: snapshot())

        XCTAssertEqual(Set(result.tracks.map(\.remoteUniqueId)), ["r1", "l1"])
        XCTAssertFalse(result.missedEverything)
    }

    // MARK: - Shaping

    func test_multipleSources_interleaveRatherThanConcatenate() {
        var recipe = PlaylistRecipe(name: "Mix", artists: ["Radiohead"], chats: ["LoFi Beats HQ"])
        recipe.trackCount = 4

        let result = RecipeSelector.select(recipe, from: snapshot())

        // Round-robin: artist, chat, artist, chat — not two artist tracks then two chat tracks.
        XCTAssertEqual(result.tracks.map(\.remoteUniqueId), ["r1", "l1", "r2", "l2"])
    }

    func test_trackCount_isRespectedAndClamped() {
        var recipe = PlaylistRecipe(name: "Mix", chats: ["LoFi Beats HQ"])
        recipe.trackCount = 2
        XCTAssertEqual(RecipeSelector.select(recipe, from: snapshot()).tracks.count, 2)

        recipe.trackCount = 9_999
        XCTAssertLessThanOrEqual(RecipeSelector.select(recipe, from: snapshot()).tracks.count,
                                 PlaylistRecipe.Limits.maxTracks)

        recipe.trackCount = 0
        XCTAssertEqual(RecipeSelector.select(recipe, from: snapshot()).tracks.count, 1,
                       "a zero count clamps up to the minimum, never to an empty playlist")
    }

    func test_duplicatesAcrossSources_appearOnce() {
        // r1 is both a Radiohead track and a favorite.
        var recipe = PlaylistRecipe(name: "Mix", artists: ["Radiohead"])
        recipe.trackCount = 50

        let result = RecipeSelector.select(recipe, from: snapshot())

        XCTAssertEqual(Set(result.tracks.map(\.remoteUniqueId)).count, result.tracks.count)
    }

    func test_scopeNarrowsAMatchedArtist() {
        var recipe = PlaylistRecipe(name: "Mix", artists: ["Radiohead"], scope: .downloaded)
        recipe.trackCount = 50

        let result = RecipeSelector.select(recipe, from: snapshot())

        XCTAssertEqual(result.tracks.map(\.remoteUniqueId), ["r2"], "only the downloaded one")
    }

    /// A scope that would empty a genuine match keeps the match — returning nothing for
    /// "downloaded Björk" when Björk exists is worse than ignoring the narrowing.
    func test_scopeThatWouldEmptyAMatch_keepsTheMatch() {
        let recipe = PlaylistRecipe(name: "Mix", artists: ["Björk"], scope: .downloaded)

        let result = RecipeSelector.select(recipe, from: snapshot())

        XCTAssertEqual(result.tracks.map(\.remoteUniqueId), ["b1"])
    }

    // MARK: - Ordering

    func test_mostPlayed_ordersByPlayCount() {
        var recipe = PlaylistRecipe(name: "Mix", artists: ["Radiohead"], chats: ["LoFi Beats HQ"])
        recipe.trackCount = 50
        recipe.sort = .mostPlayed

        let result = RecipeSelector.select(recipe, from: snapshot())

        XCTAssertEqual(result.tracks.prefix(2).map(\.remoteUniqueId), ["l1", "r1"])
    }

    func test_newest_ordersByMessageDate() {
        var s = snapshot()
        s.tracksByChat[10] = [track("old", date: 100), track("new", date: 900), track("mid", date: 500)]
        var recipe = PlaylistRecipe(name: "Mix", chats: ["LoFi Beats HQ"])
        recipe.sort = .newest

        let result = RecipeSelector.select(recipe, from: s)

        XCTAssertEqual(result.tracks.map(\.remoteUniqueId), ["new", "mid", "old"])
    }

    /// The preview the user confirms must be the playlist they get.
    func test_randomIsSeeded_soThePreviewIsStable() {
        var recipe = PlaylistRecipe(name: "Deterministic", chats: ["LoFi Beats HQ"])
        recipe.sort = .random
        recipe.trackCount = 50

        let first = RecipeSelector.select(recipe, from: snapshot()).tracks.map(\.remoteUniqueId)
        let second = RecipeSelector.select(recipe, from: snapshot()).tracks.map(\.remoteUniqueId)

        XCTAssertEqual(first, second)
    }

    func test_emptyName_fallsBackRatherThanShippingABlankPlaylist() {
        let recipe = PlaylistRecipe(name: "   ", scope: .favorites)

        XCTAssertEqual(RecipeSelector.select(recipe, from: snapshot()).name, "New Playlist")
    }

    // MARK: - Codable (the wire shape a model-backed Composer will decode into)

    func test_recipeRoundTripsThroughJSON() throws {
        let recipe = PlaylistRecipe(name: "Chill Radiohead", artists: ["Radiohead"],
                                    chats: ["LoFi Beats HQ"], moods: ["chill"],
                                    scope: .downloaded, trackCount: 12, sort: .mostPlayed)

        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(PlaylistRecipe.self, from: data)

        XCTAssertEqual(decoded, recipe)
    }

    func test_recipeDecodesFromMinimalJSON_soAPartialModelReplyStillWorks() throws {
        let json = Data(#"{"name":"Just A Name"}"#.utf8)

        let decoded = try JSONDecoder().decode(PlaylistRecipe.self, from: json)

        XCTAssertEqual(decoded.name, "Just A Name")
        XCTAssertEqual(decoded.scope, .everything)
        XCTAssertEqual(decoded.trackCount, PlaylistRecipe.Limits.defaultTracks)
        XCTAssertTrue(decoded.artists.isEmpty)
    }

    /// A model that emits a scope or sort outside our enum must not cost the user their playlist.
    func test_unknownEnumValues_degradeToDefaults() throws {
        let json = Data(#"{"name":"X","scope":"liked","sort":"vibes","trackCount":8}"#.utf8)

        let decoded = try JSONDecoder().decode(PlaylistRecipe.self, from: json)

        XCTAssertEqual(decoded.scope, .everything)
        XCTAssertEqual(decoded.sort, .relevance)
        XCTAssertEqual(decoded.trackCount, 8, "valid fields still survive alongside invalid ones")
    }

    /// `name` is the one field with no sensible default — without it there is no request.
    func test_missingName_isStillAnError() {
        let json = Data(#"{"artists":["Radiohead"]}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(PlaylistRecipe.self, from: json))
    }

    // MARK: - What leaves the device

    /// A private chat's title is a person's name. It stays selectable on-device but must never be
    /// volunteered to a Composer, which may be a third-party model behind a network call.
    func test_privateChatNames_areWithheldFromTheRoster() {
        var s = LibrarySnapshot()
        s.chats = [.init(id: 1, title: "LoFi Beats HQ"),
                   .init(id: 2, title: "Sara Ahmadi", isPrivate: true)]

        XCTAssertEqual(s.roster.chats, ["LoFi Beats HQ"])
    }

    /// ...but the user naming it themselves still works, because selection reads `chats`, not the
    /// roster.
    func test_privateChatIsStillSelectableLocally() {
        var s = LibrarySnapshot()
        s.chats = [.init(id: 2, title: "Sara Ahmadi", isPrivate: true)]
        s.tracksByChat = [2: [track("x")]]

        let result = RecipeSelector.select(PlaylistRecipe(name: "M", chats: ["Sara Ahmadi"]), from: s)

        XCTAssertEqual(result.tracks.map(\.remoteUniqueId), ["x"])
    }

    /// The roster is the entire payload boundary: names only, never ids.
    func test_rosterCarriesNamesOnly() {
        var s = LibrarySnapshot()
        s.artists = ["Radiohead"]
        s.chats = [.init(id: 99, title: "LoFi Beats HQ")]
        s.tracksByChat = [99: [track("secretish")]]
        s.playCounts = ["secretish": 5]

        let roster = s.roster

        XCTAssertEqual(roster.artists, ["Radiohead"])
        XCTAssertEqual(roster.chats, ["LoFi Beats HQ"])
        // Nothing else is reachable from a roster — it has exactly two fields, both [String].
        XCTAssertFalse(roster.chats.contains { $0.contains("99") })
    }
}

import XCTest
@testable import GramMusic

final class LyricsResolverTests: XCTestCase {
    func test_syncedLyricsTrimBlankPlaybackEdgesButKeepVerseBreaks() throws {
        let lyrics = try XCTUnwrap(Lyrics.parse("[00:00.00]\n[00:03.00] First verse\n[00:08.00] \n[00:10.00] Last verse\n[00:15.00]   ", source: .lrclib))
        XCTAssertEqual(lyrics.lines.map(\.text), ["First verse", "", "Last verse"])
        XCTAssertEqual(lyrics.syncedLines.map(\.time), [3, 8, 10])
    }

    func test_oldCachedLyricsAlsoTrimWhitespaceEdgesForDisplay() {
        let lyrics = Lyrics(lines: [LyricLine(time: 0, text: "  "),
                                    LyricLine(time: 3, text: "First"),
                                    LyricLine(time: 8, text: ""),
                                    LyricLine(time: 10, text: "Last"),
                                    LyricLine(time: 15, text: "\t")], source: .embedded)
        XCTAssertEqual(lyrics.displayLines.map(\.text), ["First", "", "Last"])
        XCTAssertEqual(lyrics.syncedLines.map(\.time), [3, 8, 10])
    }

    func test_plainLyricsKeepInteriorSpacingAndBlankLyricsAreUnavailable() throws {
        let lyrics = try XCTUnwrap(Lyrics.parse(" \n\t\nFirst\n\nLast\n \n", source: .embedded))
        XCTAssertEqual(lyrics.lines.map(\.text), ["First", "", "Last"])
        XCTAssertNil(Lyrics.parse("[00:00.00] \n[00:05.00]\t", source: .lrclib))
    }

    func test_apiWinsOverEmbeddedLyrics() async {
        let resolver = LyricsResolver(store: nil)
        let result = await resolver.lyrics(for: "track", offline: false,
            api: { "[00:01]API lyrics" }, embedded: { "File lyrics" })
        XCTAssertEqual(result?.source, .lrclib)
        XCTAssertEqual(result?.lines.first?.text, "API lyrics")
    }

    func test_apiMissFallsBackToFile() async {
        let resolver = LyricsResolver(store: nil)
        let result = await resolver.lyrics(for: "track", offline: false,
            api: { nil }, embedded: { "File lyrics" })
        XCTAssertEqual(result?.source, .embedded)
    }

    func test_oldEmbeddedCacheDoesNotBlockAPI() async throws {
        let store = InMemoryArtworkStore()
        let old = Lyrics(lines: [LyricLine(time: nil, text: "File lyrics")], source: .embedded)
        await store.store(try JSONEncoder().encode(old), for: "track")
        let resolver = LyricsResolver(store: store)
        let result = await resolver.lyrics(for: "track", offline: false,
            api: { "API lyrics" }, embedded: { nil })
        XCTAssertEqual(result?.source, .lrclib)
    }

    func test_offlineFileLyricsUpgradeWhenOnline() async {
        let resolver = LyricsResolver(store: nil)
        let offline = await resolver.lyrics(for: "track", offline: true,
            api: { XCTFail("Offline lookup must not call the API"); return nil },
            embedded: { "File lyrics" })
        XCTAssertEqual(offline?.source, .embedded)
        let online = await resolver.lyrics(for: "track", offline: false,
            api: { "API lyrics" }, embedded: { nil })
        XCTAssertEqual(online?.source, .lrclib)
    }

    func test_apiCacheSurvivesRelaunchAndWorksOffline() async {
        let store = InMemoryArtworkStore()
        let resolver = LyricsResolver(store: store)
        _ = await resolver.lyrics(for: "track", offline: false,
            api: { "API lyrics" }, embedded: { nil })
        let relaunched = LyricsResolver(store: store)
        let result = await relaunched.lyrics(for: "track", offline: true,
            api: { XCTFail("Offline lookup must not call the API"); return nil }, embedded: { nil })
        XCTAssertEqual(result?.source, .lrclib)
    }

    func test_fileMissRetriesAfterDownload() async {
        let resolver = LyricsResolver(store: nil)
        let first = await resolver.lyrics(for: "track", offline: false,
            api: { nil }, embedded: { nil })
        XCTAssertNil(first)
        let afterDownload = await resolver.lyrics(for: "track", offline: false,
            api: { XCTFail("API miss is recorded for this session"); return nil },
            embedded: { "File lyrics" })
        XCTAssertEqual(afterDownload?.source, .embedded)
    }
}

import XCTest
@testable import GramMusic

@MainActor
final class SearchSourceStoreTests: XCTestCase {
    private let a = MusicSearchBot(id: 101, username: "firstbot")
    private let b = MusicSearchBot(id: 102, username: "secondbot")

    private func withDefaults(_ test: (UserDefaults) throws -> Void) rethrows {
        let name = "SearchSourceStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try test(defaults)
    }

    func test_homeDefaultAndBotConnectionsSurviveRelaunch() {
        withDefaults { defaults in
            let store = SearchSourceStore(defaults: defaults)
            XCTAssertEqual(store.sources, [.telegram])
            store.add(a); store.add(b); store.setDefault(.bot(b))
            let restored = SearchSourceStore(defaults: defaults)
            XCTAssertEqual(restored.sources, [.telegram, .bot(a), .bot(b)])
            XCTAssertEqual(restored.defaultSource, .bot(b))
        }
    }

    func test_removeDefaultFallsBackToTelegramAndPersists() {
        withDefaults { defaults in
            let store = SearchSourceStore(defaults: defaults)
            store.add(a); store.add(b); store.setDefault(.bot(a)); store.remove(a)
            XCTAssertEqual(store.defaultSource, .telegram)
            XCTAssertEqual(SearchSourceStore(defaults: defaults).defaultSource, .telegram)
            XCTAssertEqual(store.bots, [b])
        }
    }

    func test_duplicateAndRenamedBotDoNotCreateExtraTabs() {
        withDefaults { defaults in
            let store = SearchSourceStore(defaults: defaults)
            store.add(a); store.add(a); store.setDefault(.bot(a))
            let renamed = MusicSearchBot(id: a.id, username: "renamedbot")
            store.add(renamed)
            XCTAssertEqual(store.bots, [renamed])
            XCTAssertEqual(store.defaultSource, .bot(renamed))
        }
    }

    func test_unknownDefaultAndMalformedDataRecoverToTelegram() {
        withDefaults { defaults in
            defaults.set(Data("broken".utf8), forKey: StorageKeys.searchBots)
            defaults.set("bot:404", forKey: StorageKeys.defaultSearchSource)
            let store = SearchSourceStore(defaults: defaults)
            XCTAssertEqual(store.sources, [.telegram])
            XCTAssertEqual(store.defaultSource, .telegram)
        }
    }

    func test_clearErasesMemoryAndAccountPreferences() {
        withDefaults { defaults in
            let store = SearchSourceStore(defaults: defaults)
            store.add(a); store.setDefault(.bot(a)); store.clear()
            XCTAssertEqual(store.sources, [.telegram])
            XCTAssertEqual(store.defaultSource, .telegram)
            XCTAssertNil(defaults.object(forKey: StorageKeys.searchBots))
            XCTAssertNil(defaults.object(forKey: StorageKeys.defaultSearchSource))
            XCTAssertEqual(store.generation, 1, "In-flight connects must be invalidated by sign-out")
        }
        XCTAssertTrue(StorageKeys.perAccount.contains(StorageKeys.searchBots))
        XCTAssertTrue(StorageKeys.perAccount.contains(StorageKeys.defaultSearchSource))
    }

    func test_usernamesNormalizeAndRejectURLsAndSearchExpressions() throws {
        XCTAssertEqual(try MusicSearchBot.normalizedUsername("  @DeezerMusicBot\n"), "deezermusicbot")
        for invalid in ["", "https://t.me/musicbot", "@musicbot song", "@x", "@12345", "@موسیقی"] {
            XCTAssertThrowsError(try MusicSearchBot.normalizedUsername(invalid))
        }
    }
    func test_connectionExpressionSeparatesUsernameAndOptionalPrefix() throws {
        let parsed = try MusicSearchBot.parseConnection("  @DeezerMusicBot music ")
        XCTAssertEqual(parsed.username, "deezermusicbot")
        XCTAssertEqual(parsed.queryPrefix, "music")
        let plain = try MusicSearchBot.parseConnection("@musicbot  ")
        XCTAssertNil(plain.queryPrefix)
        let command = try MusicSearchBot.parseConnection("@musicbot search music")
        XCTAssertEqual(command.queryPrefix, "search music")
        for invalid in ["", "https://t.me/musicbot music", "@12345 music", "@x music"] {
            XCTAssertThrowsError(try MusicSearchBot.parseConnection(invalid))
        }
    }

    func test_optionalNameAndPrefixSurviveRelaunchAndEditingKeepsDefault() {
        withDefaults { defaults in
            let store = SearchSourceStore(defaults: defaults)
            let named = MusicSearchBot(id: a.id, username: a.username, displayName: "  My music  ", queryPrefix: " music ")
            store.add(named)
            store.setDefault(.bot(named))
            let restored = SearchSourceStore(defaults: defaults)
            XCTAssertEqual(restored.defaultSource.label, "My music")
            XCTAssertEqual(restored.bots.first?.queryPrefix, "music")
            restored.update(named, displayName: "  ", queryPrefix: " ")
            XCTAssertEqual(restored.defaultSourceID, MusicSearchSource.bot(named).id)
            XCTAssertEqual(restored.defaultSource.label, "@firstbot")
            XCTAssertNil(restored.bots.first?.displayName)
            XCTAssertNil(restored.bots.first?.queryPrefix)
            XCTAssertEqual(SearchSourceStore(defaults: defaults).bots.first?.label, "@firstbot")
        }
    }

    func test_legacyConnectionsDecodeWithoutLosingDefault() {
        withDefaults { defaults in
            defaults.set(Data("[{\"id\":101,\"username\":\"firstbot\"}]".utf8), forKey: StorageKeys.searchBots)
            defaults.set("bot:101", forKey: StorageKeys.defaultSearchSource)
            let restored = SearchSourceStore(defaults: defaults)
            XCTAssertEqual(restored.bots, [a])
            XCTAssertEqual(restored.defaultSourceID, "bot:101")
            XCTAssertNil(restored.bots.first?.displayName)
            XCTAssertNil(restored.bots.first?.queryPrefix)
        }
    }

    func test_staleEditorCannotRestoreRemovedBot() {
        withDefaults { defaults in
            let store = SearchSourceStore(defaults: defaults)
            store.add(a)
            store.remove(a)
            store.update(a, displayName: "Music", queryPrefix: "music")
            XCTAssertTrue(store.bots.isEmpty)
        }
    }

}

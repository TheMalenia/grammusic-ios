import XCTest
import SwiftUI
import SwiftData
import Observation
@testable import GramMusic

@MainActor
final class ShellNavigationTests: XCTestCase {
    func test_playerSourceBadgeUsesPlaybackContextBeforeMembershipMatches() {
        let track = AudioTrack(chatId: 42, messageId: 7, fileId: 9, remoteUniqueId: "profile-source",
                               title: "Profile track", performer: "Artist", duration: 90)
        let chat = TelegramChat(id: 42, title: "Source chat", kind: .channel)
        let profile = UserProfilePlaylist(userId: 42, chatId: 42, userName: "Source user",
                                          tracks: [track])

        XCTAssertEqual(NPlayerSourceRoute.resolve(track: track, contextName: chat.title, chats: [chat],
                                                  profiles: [profile], isOwnProfileAudio: true), .chat(chat),
                       "A chat playback context must remain a chat even if the track is also on profiles")
        XCTAssertEqual(NPlayerSourceRoute.resolve(track: track, contextName: profile.title, chats: [chat],
                                                  profiles: [profile], isOwnProfileAudio: false), .profile(profile),
                       "A profile playback context must win when the profile and chat share an id")
        XCTAssertEqual(
            NPlayerSourceRoute.resolve(track: track, contextName: "Your Profile", chats: [chat],
                                       profiles: [profile], isOwnProfileAudio: true),
            .ownProfile
        )
        XCTAssertEqual(
            NPlayerSourceRoute.resolve(track: track, contextName: nil, chats: [chat],
                                       profiles: [], isOwnProfileAudio: false),
            .chat(chat)
        )
        XCTAssertEqual(
            NPlayerSourceRoute.resolve(track: track, contextName: nil, chats: [],
                                       profiles: [profile], isOwnProfileAudio: true),
            .profile(profile),
            "Profile membership is a fallback only when no source chat is available"
        )
        XCTAssertEqual(
            NPlayerSourceRoute.resolve(track: track, contextName: nil, chats: [],
                                       profiles: [], isOwnProfileAudio: true),
            .ownProfile
        )
    }

    func test_tabBackdropDoesNotTurnBlackAroundExpandedPlayer() async throws {
        guard #available(iOS 26.1, *) else { throw XCTSkip("Native player requires iOS 26.1") }
        let container = try ModelContainer(for: Playlist.self, TrackRef.self,
                                          configurations: .init(isStoredInMemoryOnly: true))
        let telegram = TelegramService(backend: MockTelegramBackend())
        let player = PlayerEngine(fileProvider: { _ in URL(fileURLWithPath: "/dev/null") })
        let theme = ThemeMode.day.resolve(systemScheme: .light, accent: .default,
                                          brand: .nocturne, artwork: .gradient)
        let host = UIHostingController(rootView: NocturneAppShell()
            .environment(telegram).environment(player).environment(AppSettings())
            .environment(ImportStore()).environment(NActionFeedback())
            .environment(\.theme, theme).preferredColorScheme(.light)
            .modelContainer(container))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { player.stop(); window.isHidden = true; window.rootViewController = nil }
        let song = AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: "backdrop",
                              title: "Backdrop song", performer: "Artist", duration: 100)
        player.play(tracks: [song])
        try await settle(host)
        let tabs = try XCTUnwrap(tabController(in: host))
        for index in [0, 1, 3, 0] {
            tabs.selectedIndex = index
            tabs.delegate?.tabBarController?(tabs, didSelect: try XCTUnwrap(tabs.viewControllers?[index]))
            try await settle(host)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Native bar backdrop tab \(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let bitmap = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(bitmap.bitsPerComponent, 8)
            let bytes = try XCTUnwrap(bitmap.dataProvider?.data)
            let pixels = try XCTUnwrap(CFDataGetBytePtr(bytes))
            // Sample the uncovered gutter beside the glass, not its shadows or controls.
            for y in [Int(window.bounds.height) - 145, Int(window.bounds.height) - 80] {
                let offset = y * bitmap.bytesPerRow + 4 * (bitmap.bitsPerPixel / 8)
                let brightness = (Double(pixels[offset]) + Double(pixels[offset + 1]) + Double(pixels[offset + 2])) / (3 * 255)
                XCTAssertGreaterThan(brightness, 0.6, "The light canvas must extend behind the expanded bar")
            }
        }
    }

    func test_localSearchPushKeepsTabsAndSharedPlayer() async throws {
        guard #available(iOS 26.1, *) else { throw XCTSkip("Native player requires iOS 26.1") }
        let container = try ModelContainer(for: Playlist.self, TrackRef.self,
                                          configurations: .init(isStoredInMemoryOnly: true))
        let suite = "SearchUnderlayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let telegram = TelegramService(backend: MockTelegramBackend(),
                                       hiddenTracks: HiddenTracksStore(defaults: defaults))
        telegram.blockedChatIds = []
        let player = PlayerEngine(fileProvider: { _ in URL(fileURLWithPath: "/dev/null") })
        let navigation = LocalSearchNavigationState()
        let songs = (0..<36).map { index in
            AudioTrack(chatId: 1, messageId: Int64(index + 1), fileId: index + 1,
                       remoteUniqueId: "chat-search-\(index)", title: "Chat song \(index)",
                       performer: "Artist \(index)", duration: 100)
        }
        XCTAssertEqual(telegram.visible(songs).count, 36, "Fixture songs must not inherit stored account exclusions")
        let host = UIHostingController(rootView: LocalSearchNavigationFixture(state: navigation, tracks: songs)
            .environment(telegram).environment(player).environment(AppSettings())
            .environment(NActionFeedback()).modelContainer(container)
            .environment(\.theme, ThemeMode.day.resolve(systemScheme: .light, accent: .default,
                                                       brand: .nocturne, artwork: .gradient))
            .preferredColorScheme(.light)
            .transaction { $0.disablesAnimations = true })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { player.stop(); window.isHidden = true; window.rootViewController = nil }
        player.play(tracks: [songs[0]])
        try await settle(host)
        let tabs = try XCTUnwrap(tabController(in: host))
        let chatTab = tabs.selectedViewController
        navigation.path = [1]
        try await settle(host)
        let localField = try XCTUnwrap(searchField(in: host.view), "Chat search exposes the regular search field")
        XCTAssertTrue(localField.isFirstResponder)
        XCTAssertEqual(localField.placeholder, "Find in My channel")
        XCTAssertNil(host.presentedViewController, "Search must stay in its tab rather than cover it")
        XCTAssertTrue(tabs.selectedViewController === chatTab)
        XCTAssertFalse(tabs.tabBar.isHidden)
        XCTAssertNotNil(tabs.bottomAccessory, "Chat search shares the existing player accessory")
        localField.resignFirstResponder()
        try await settle(host)
        XCTAssertFalse(localField.isFirstResponder, "Dismiss the keyboard so the bottom glass and long results are visible")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Chat search with shared bottom bar and page close"
        attachment.lifetime = .keepAlways
        add(attachment)
        let resultsScroll = try XCTUnwrap(verticalScrollView(in: host.view), "Local song results must use a vertical scroll viewport")
        let resultsBottom = resultsScroll.convert(resultsScroll.bounds, to: host.view.window).maxY
        let tabsBottom = tabs.tabBar.convert(tabs.tabBar.bounds, to: host.view.window).maxY
        XCTAssertGreaterThan(resultsScroll.contentSize.height, resultsScroll.bounds.height,
                             "The fixture must contain enough unique tracks to scroll")
        XCTAssertGreaterThanOrEqual(resultsBottom, tabsBottom,
                                    "Search results viewport should continue behind the bottom tabs and mini-player")

        localField.becomeFirstResponder()
        try await settle(host)
        XCTAssertTrue(localField.isFirstResponder, "Restore the keyboard before exercising the native close button")
        let nav = try XCTUnwrap(navigationController(in: try XCTUnwrap(tabs.selectedViewController)))
        let item = try XCTUnwrap(nav.navigationBar.topItem)
        let items = (item.rightBarButtonItems ?? []) + item.trailingItemGroups.flatMap(\.barButtonItems)
        let close = try XCTUnwrap(items.last, "The page close button must remain available while typing")
        let action = try XCTUnwrap(close.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: close.target, from: close, for: nil))
        try await settle(host)
        XCTAssertEqual(navigation.path, [], "One X tap must pop the page, including while the keyboard is active")
        XCTAssertTrue(tabs.selectedViewController === chatTab)
        XCTAssertNotNil(tabs.bottomAccessory)
    }

    func test_nativePlayerStartsPausesAndStopsWithoutResettingLibrary() async throws {
        guard #available(iOS 26.1, *) else { throw XCTSkip("Native player requires iOS 26.1") }
        let container = try ModelContainer(for: Playlist.self, TrackRef.self,
                                          configurations: .init(isStoredInMemoryOnly: true))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ShellNavigationTests"))
        defer { defaults.removePersistentDomain(forName: "ShellNavigationTests") }
        let telegram = TelegramService(backend: MockTelegramBackend())
        let player = PlayerEngine(fileProvider: { _ in URL(fileURLWithPath: "/dev/null") })
        let input = NSearchInput()
        let root = NocturneAppShell(searchInput: input)
            .environment(telegram)
            .environment(player)
            .environment(AppSettings(defaults: defaults))
            .environment(ImportStore())
            .environment(NActionFeedback())
            .modelContainer(container)
            .transaction { $0.disablesAnimations = true }
        let host = UIHostingController(rootView: root)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { player.stop(); window.isHidden = true; window.rootViewController = nil }
        try await settle(host)
        let tabs = try XCTUnwrap(tabController(in: host))
        let destinations = try XCTUnwrap(tabs.viewControllers)
        XCTAssertEqual(destinations.count, 4)
        XCTAssertEqual(tabs.tabBar.items?.last?.title, "Search")
        let searchItem = try XCTUnwrap(tabs.tabBar.items?.last)
        tabs.selectedIndex = 3
        tabs.delegate?.tabBarController?(tabs, didSelect: destinations[3])
        try await settle(host)
        let searchField = try XCTUnwrap(searchField(in: host.view), "Search tab must expose a native search field")
        XCTAssertFalse(searchField.isFirstResponder, "First tap opens the Search page without the keyboard")
        let fieldFrame = searchField.convert(searchField.bounds, to: window)
        XCTAssertGreaterThan(fieldFrame.width, 100, "Search input must be visibly expanded")
        XCTAssertGreaterThan(fieldFrame.height, 20)
        XCTAssertTrue(window.bounds.intersects(fieldFrame), "Input must be on screen")
        XCTAssertLessThan(fieldFrame.maxY, 300, "Search input belongs at the top of the page")
        tabs.delegate?.tabBarController?(tabs, didSelect: destinations[3])
        try await settle(host)
        XCTAssertTrue(searchField.isFirstResponder, "Second Search tap focuses the top field")
        searchField.insertText("remember this search")
        searchField.sendActions(for: .editingChanged)
        try await settle(host)
        XCTAssertEqual(input.text, "remember this search", "Typing must reach the shared search query")
        searchField.resignFirstResponder()
        tabs.selectedIndex = 1
        tabs.delegate?.tabBarController?(tabs, didSelect: destinations[1])
        try await settle(host)
        XCTAssertNil(tabs.bottomAccessory, "No loaded song should leave no empty player bar")

        let song = AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: "shell-layout",
                              title: "Shell layout", performer: "Artist", duration: 100)
        player.play(tracks: [song], context: "Test")
        try await settle(host)
        XCTAssertNotNil(tabs.bottomAccessory)
        XCTAssertEqual(tabs.selectedIndex, 1)
        XCTAssertTrue(tabs.selectedViewController === destinations[1])

        player.pause()
        try await settle(host)
        XCTAssertNotNil(tabs.bottomAccessory, "Paused songs must remain available to resume")

        player.stop()
        try await settle(host)
        XCTAssertNil(tabs.bottomAccessory, "Stopping must remove the player, including its space")
        XCTAssertTrue(tabs.tabBar.items?.last === searchItem, "Playback changes must not replace the Search tab")
        XCTAssertEqual(tabs.selectedIndex, 1)
        XCTAssertTrue(tabs.selectedViewController === destinations[1])
        tabs.selectedIndex = 3
        tabs.delegate?.tabBarController?(tabs, didSelect: destinations[3])
        try await settle(host)
        XCTAssertTrue(tabs.selectedViewController === destinations[3])
        XCTAssertEqual(input.text, "remember this search")
        XCTAssertEqual(self.searchField(in: host.view)?.text, "remember this search",
                       "Returning to Search after playback transitions must preserve its query")
        let restoredField = try XCTUnwrap(self.searchField(in: host.view))
        XCTAssertFalse(restoredField.isFirstResponder, "Returning opens the page before the keyboard")
        tabs.delegate?.tabBarController?(tabs, didSelect: destinations[3])
        try await settle(host)
        XCTAssertTrue(restoredField.isFirstResponder)
        restoredField.text = ""
        restoredField.sendActions(for: .editingChanged)
        try await settle(host)
        XCTAssertEqual(input.text, "", "Clearing the visible field must also clear results")
    }

    private func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.navigationController(in: $0) }.first
    }

    private func tabController(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { self.tabController(in: $0) }.first
    }

    private func searchField(in view: UIView) -> UITextField? {
        let fields = searchFields(in: view)
        return fields.first(where: \.isFirstResponder) ?? fields.first { field in
            guard let window = field.window, field.bounds.width > 100 else { return false }
            return window.bounds.intersects(field.convert(field.bounds, to: window))
        }
    }

    private func searchFields(in view: UIView) -> [UITextField] {
        guard !view.isHidden, view.alpha > 0 else { return [] }
        if let field = view as? UITextField { return [field] }
        return view.subviews.flatMap { self.searchFields(in: $0) }
    }

    private func verticalScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 1 {
            return scroll
        }
        return view.subviews.lazy.compactMap { self.verticalScrollView(in: $0) }.first
    }

    private func settle(_ host: UIViewController) async throws {
        for _ in 0..<20 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor @Observable
private final class LocalSearchNavigationState {
    var path: [Int] = []
}

@available(iOS 26.1, *)
private struct LocalSearchNavigationFixture: View {
    @Bindable var state: LocalSearchNavigationState
    let tracks: [AudioTrack]
    @Environment(PlayerEngine.self) private var player
    @State private var globalInput = NSearchInput()

    var body: some View {
        TabView {
            Tab("Library", systemImage: "books.vertical") {
                NavigationStack(path: $state.path) {
                    Text("Chat songs")
                        .navigationDestination(for: Int.self) { _ in
                            NSearchView(localScope: .init(title: "My channel", tracks: tracks, context: "My channel"),
                                        isTab: true, embeddedInNavigation: true, onClose: { state.path = [] })
                        }
                }
            }
            Tab("Search", systemImage: "magnifyingglass", role: .search) { NSearchView(isTab: true, sharedInput: globalInput) }
        }
        .tabViewBottomAccessory(isEnabled: player.current != nil) { NTabMiniPlayer(onExpand: {}, onTopChange: { _ in }) }
        .environment(\.nUsesNativePlayerAccessory, true)
    }
}

import XCTest
import SwiftUI
import Observation
@testable import GramMusic

@MainActor
final class DockSpacingTests: XCTestCase {
    func test_bothDocksKeepLastRowAbovePlayerAndOfflineNotice() async throws {
        for usesNative in [false, true] {
            for size in [CGSize(width: 320, height: 568), CGSize(width: 393, height: 852)] {
                for typeSize in [DynamicTypeSize.large, .accessibility3] {
                    let telegram = TelegramService(backend: MockTelegramBackend())
                    let player = PlayerEngine(fileProvider: { _ in URL(fileURLWithPath: "/dev/null") })
                    let capture = DockLayoutCapture()
                    let host = UIHostingController(rootView: DockModeFixture(capture: capture, usesNative: usesNative)
                        .environment(telegram).environment(player)
                        .environment(\.dynamicTypeSize, typeSize)
                        .transaction { $0.disablesAnimations = true })
                    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                    let window = UIWindow(windowScene: scene)
                    window.frame = CGRect(origin: .zero, size: size)
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    defer { player.stop(); window.isHidden = true; window.rootViewController = nil }
                    try await settle(host)
                    XCTAssertEqual(window.bounds.size, size, "Fixture must retain its requested viewport")
                    let song = AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: "spacing",
                                          title: "A song with a longer title", performer: "Artist", duration: 100)
                    player.play(tracks: [song])
                    try await settle(host)
                    if #available(iOS 26.1, *), usesNative {
                        XCTAssertGreaterThan(capture.scrollViewportBottom,
                                             try XCTUnwrap(capture.top),
                                             "Native scroll viewport should extend behind the mini-player at \(size), \(typeSize)")
                        XCTAssertGreaterThanOrEqual(capture.scrollViewportBottom,
                                             window.bounds.maxY - window.safeAreaInsets.bottom,
                                             "Native scroll viewport should extend below the bottom safe area at \(size), \(typeSize)")
                    }
                    try await scrollToBottom(host, capture: capture)
                    XCTAssertLessThanOrEqual(capture.lastRowBottom, try XCTUnwrap(capture.safeTop),
                                             "Last row overlaps player at \(size), \(typeSize)")
                    telegram.isOfflineStable = true
                    try await settle(host)
                    if #available(iOS 26.1, *), usesNative {
                        XCTAssertGreaterThanOrEqual(capture.scrollViewportBottom,
                                                    window.bounds.maxY - window.safeAreaInsets.bottom,
                                                    "The offline notice must not cut the scroll viewport off above the glass")
                    }
                    try await scrollToBottom(host, capture: capture)
                    XCTAssertLessThanOrEqual(capture.lastRowBottom, try XCTUnwrap(capture.safeTop),
                                             "Last row overlaps offline notice at \(size), \(typeSize)")
                    player.stop()
                    try await settle(host)
                    try await scrollToBottom(host, capture: capture)
                    XCTAssertLessThanOrEqual(capture.lastRowBottom, try XCTUnwrap(capture.safeTop),
                                             "Offline-only dock overlaps last row")
                }
            }
        }
    }

    private func scrollToBottom(_ host: UIViewController, capture: DockLayoutCapture) async throws {
        let scroll = try XCTUnwrap(scrollView(in: host.view))
        scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
        try await settle(host)
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if view.isHidden || view.alpha == 0 { return nil }
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func settle(_ host: UIViewController) async throws {
        for _ in 0..<30 {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
@Observable
private final class DockLayoutCapture {
    var top: CGFloat?
    var offlineTop: CGFloat?
    var scrollViewportBottom: CGFloat = 0
    var safeTop: CGFloat? { [top, offlineTop].compactMap { $0 }.min() }
    var lastRowBottom: CGFloat = 0
}

private struct DockScrollFixture: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(TelegramService.self) private var telegram
    let capture: DockLayoutCapture

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(0..<30) { index in Text("Song \(index)").frame(minHeight: 44) }
                Text("Last song").frame(minHeight: 44)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { capture.lastRowBottom = $0 }
            }
            .nMiniPlayerClearance(player.current != nil, offline: telegram.isOfflineStable, base: 16)
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
            capture.scrollViewportBottom = $0
        }
        .modifier(NScrollDockViewport())
    }
}

private struct DockModeFixture: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(TelegramService.self) private var telegram
    let capture: DockLayoutCapture
    let usesNative: Bool

    var body: some View {
        if #available(iOS 26.1, *), usesNative {
            TabView {
                Tab("Home", systemImage: "house") {
                    NavigationStack {
                        DockScrollFixture(capture: capture)
                            .toolbar(.hidden, for: .navigationBar)
                    }
                        .modifier(NOfflineDock(onTopChange: { capture.offlineTop = $0 }))
                }
                Tab("Search", systemImage: "magnifyingglass", role: .search) { Color.clear }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory(isEnabled: player.current != nil) {
                NTabMiniPlayer(onExpand: {}, onTopChange: { capture.top = $0 })
            }
            .environment(\.nUsesNativePlayerAccessory, true)
            .environment(\.nMiniDockTop, capture.safeTop)
            .onChange(of: player.current == nil) { _, empty in if empty { capture.top = nil } }
        } else {
            DockScrollFixture(capture: capture)
                .nMiniDock(onDockTopChange: { capture.top = $0 }) { }
        }
    }
}

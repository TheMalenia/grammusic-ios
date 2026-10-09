import XCTest
import SwiftUI
import Observation
@testable import GramMusic

@MainActor
final class TrackSelectionTests: XCTestCase {
    private func track(_ id: String, messageId: Int64 = 1) -> AudioTrack {
        AudioTrack(chatId: 1, messageId: messageId, fileId: 1, remoteUniqueId: id,
                   title: id, performer: "", duration: 1)
    }

    func test_anySelectedHiddenSongSwitchesActionUntilItIsDeselected() {
        let selection = NTrackSelection()
        let visible = track("visible")
        let hidden = track("hidden", messageId: 2)
        selection.begin(visible)
        XCTAssertFalse(selection.containsHidden(in: [visible, hidden], hiddenIDs: ["hidden"]))
        selection.toggle(hidden)
        XCTAssertTrue(selection.containsHidden(in: [visible, hidden], hiddenIDs: ["hidden"]))
        selection.toggle(hidden)
        XCTAssertFalse(selection.containsHidden(in: [visible, hidden], hiddenIDs: ["hidden"]))
    }

    func test_selectAllRecognizesHiddenSongsLoadedLaterAndRespectsExclusions() {
        let selection = NTrackSelection()
        let visible = track("visible")
        let hidden = track("hidden", messageId: 2)
        selection.begin(visible)
        selection.selectAll([visible])
        XCTAssertTrue(selection.containsHidden(in: [visible, hidden], hiddenIDs: ["hidden"]))
        selection.toggle(hidden)
        XCTAssertFalse(selection.containsHidden(in: [visible, hidden], hiddenIDs: ["hidden"]))
    }

    func test_holdStartsSelectionAndTapsToggleMembership() {
        let selection = NTrackSelection()
        selection.begin(track("a"))
        selection.toggle(track("b"))
        XCTAssertTrue(selection.isSelecting)
        XCTAssertEqual(selection.ids, ["a", "b"])
        selection.toggle(track("a"))
        selection.toggle(track("b"))
        XCTAssertTrue(selection.isSelecting, "Deselecting the last track must not resume playback on the next tap")
        XCTAssertTrue(selection.ids.isEmpty)
        selection.cancel()
        XCTAssertFalse(selection.isSelecting)
    }

    func test_selectAllDeduplicatesAudioAndKeepsScreenOrder() {
        let selection = NTrackSelection()
        let source = [track("b"), track("a"), track("b", messageId: 2)]
        selection.begin(source[0])
        selection.selectAll(source)
        XCTAssertEqual(selection.selected(from: source).map(\.remoteUniqueId), ["b", "a"])
        selection.cancel()
        XCTAssertTrue(selection.ids.isEmpty)
    }
    func test_selectAllIncludesTracksLoadedLaterAndCancelResetsIntent() {
        let selection = NTrackSelection()
        selection.begin(track("a"))
        selection.selectAll([track("a")])
        XCTAssertTrue(selection.includesUnloaded)
        XCTAssertEqual(selection.selected(from: [track("a"), track("b")]).map(\.remoteUniqueId), ["a", "b"])
        selection.cancel()
        XCTAssertFalse(selection.includesUnloaded)
    }

    func test_deselectAfterSelectAllExcludesOnlyThatTrackIncludingUnloadedTracks() {
        let selection = NTrackSelection()
        selection.begin(track("a"))
        selection.selectAll([track("a"), track("b")])
        selection.toggle(track("b"))
        XCTAssertTrue(selection.includesUnloaded)
        XCTAssertFalse(selection.contains(track("b")))
        XCTAssertEqual(selection.selected(from: [track("a"), track("b"), track("c")]).map(\.remoteUniqueId), ["a", "c"])
        selection.toggle(track("c"))
        XCTAssertFalse(selection.contains(track("c")))
        selection.toggle(track("b"))
        XCTAssertTrue(selection.contains(track("b")))
    }

}

/// Exercises the real SwiftUI safe-area modifier as a dock appears after initial layout.
@MainActor
final class TrackSelectionLayoutTests: XCTestCase {
    func test_selectionMovesAboveALateDockAndReturnsWhenItDisappears() async throws {
        let track = AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: "layout",
                               title: "Layout", performer: "", duration: 1)
        let selection = NTrackSelection()
        selection.begin(track)
        let dock = SelectionDockFixture()
        let capture = SelectionLayoutCapture()
        let root = SelectionLayoutFixture(track: track, selection: selection, dock: dock, capture: capture)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        try await settle(host, until: { capture.bottom > 0 })
        let original = capture.bottom
        // The dock consumes the last 100 points of the original safe area.
        dock.top = window.bounds.maxY - window.safeAreaInsets.bottom - 100
        try await settle(host, until: { capture.bottom < original - 80 })
        XCTAssertLessThan(capture.bottom, dock.top!, "Content and selection must leave room above the dock")
        let settled = capture.bottom
        for _ in 0..<5 {
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(capture.bottom, settled, accuracy: 1, "Geometry clearance must not oscillate")

        // A taller dock (for example the offline notice) needs more clearance.
        dock.top = dock.top! - 46
        try await settle(host, until: { capture.bottom < settled - 40 })

        dock.top = nil
        try await settle(host, until: { abs(capture.bottom - original) < 1 })
        XCTAssertEqual(capture.bottom, original, accuracy: 1)
    }

    func test_alreadyInsetSelectionDoesNotAddADuplicateDockGap() async throws {
        let track = AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: "inset",
                               title: "Inset", performer: "", duration: 1)
        let selection = NTrackSelection()
        selection.begin(track)
        let dock = SelectionDockFixture()
        let capture = SelectionLayoutCapture()
        let root = SelectionLayoutFixture(track: track, selection: selection, dock: dock,
                                          capture: capture, reservedDockHeight: 100)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(host, until: { capture.bottom > 0 })
        let original = capture.bottom
        dock.top = window.bounds.maxY - window.safeAreaInsets.bottom - 100
        for _ in 0..<10 {
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(capture.bottom, original, accuracy: 1,
                       "A navigation surface already above the dock should not reserve its space twice")
    }

    func test_compactActionsDisappearWhenSelectionCloses() async throws {
        let track = AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: "compact-selection",
                               title: "Selected song", performer: "Artist", duration: 100)
        let selection = NTrackSelection()
        let capture = SelectionLayoutCapture()
        let host = UIHostingController(rootView: SelectionLayoutFixture(
            track: track, selection: selection, dock: SelectionDockFixture(), capture: capture)
            .background(ScreenBackground()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(host, until: { capture.bottom > 0 })
        let fullContentBottom = capture.bottom
        selection.begin(track)
        try await settle(host, until: { capture.bottom < fullContentBottom })
        XCTAssertLessThanOrEqual(fullContentBottom - capture.bottom, 90,
                                 "All bulk action icons should fit in a compact row on a small screen")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Compact selection icons on small screen"
        attachment.lifetime = .keepAlways
        add(attachment)
        selection.cancel()
        try await settle(host, until: { abs(capture.bottom - fullContentBottom) < 1 })
        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertEqual(capture.bottom, fullContentBottom, accuracy: 1,
                       "Closing selection must remove the toolbar and restore the viewport")
    }

    private func settle(_ host: UIViewController, until condition: () -> Bool) async throws {
        for _ in 0..<100 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("SwiftUI layout did not reach the expected dock clearance")
    }
}

@MainActor @Observable
private final class SelectionDockFixture { var top: CGFloat? }

@MainActor
private final class SelectionLayoutCapture { var bottom: CGFloat = 0 }

private struct SelectionLayoutFixture: View {
    let track: AudioTrack
    let selection: NTrackSelection
    let dock: SelectionDockFixture
    let capture: SelectionLayoutCapture
    var reservedDockHeight: CGFloat = 0

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { capture.bottom = $0 }
            .trackSelection(tracks: [track], selection: selection, destructiveTitle: "Hide songs", destructiveIcon: "eye.slash",
                            onDestructive: { _ in })
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: reservedDockHeight) }
            .environment(\.nMiniDockTop, dock.top)
            .transaction { $0.disablesAnimations = true }
    }
}

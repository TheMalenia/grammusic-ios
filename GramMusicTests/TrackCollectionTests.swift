import XCTest
@testable import GramMusic

@MainActor
final class TrackCollectionTests: XCTestCase {
    private func track(_ id: String) -> AudioTrack {
        AudioTrack(chatId: 1, messageId: 1, fileId: 1, remoteUniqueId: id,
                   title: id, performer: "", duration: 1)
    }

    func test_allPagesIncludeEmptyAudioPagesAndDeduplicateInSourceOrder() async throws {
        var offsets: [String] = []
        let tracks = try await TrackCollection.load { offset in
            offsets.append(offset)
            switch offset {
            case "": return MusicSearchPage(tracks: [self.track("a")], nextOffset: "articles")
            case "articles": return MusicSearchPage(tracks: [], nextOffset: "last", nonAudioResultCount: 10)
            default: return MusicSearchPage(tracks: [self.track("a"), self.track("b")])
            }
        }
        XCTAssertEqual(offsets, ["", "articles", "last"])
        XCTAssertEqual(tracks.map(\.remoteUniqueId), ["a", "b"])
    }

    func test_repeatedCursorCannotLoopForever() async throws {
        var requests = 0
        let tracks = try await TrackCollection.load { _ in
            requests += 1
            return MusicSearchPage(tracks: [self.track("a")], nextOffset: "same")
        }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(tracks.count, 1)
    }

    func test_failedLaterPageDoesNotCommitPartialSelection() async {
        let addition = NPlaylistAddition()
        var committed = false
        let success = await addition.add(load: {
            try await TrackCollection.load { offset in
                if offset.isEmpty { return MusicSearchPage(tracks: [self.track("a")], nextOffset: "next") }
                throw TelegramError.backend("Offline")
            }
        }, commit: { _ in committed = true })
        XCTAssertFalse(success)
        XCTAssertFalse(committed)
        XCTAssertNotNil(addition.error)
        XCTAssertFalse(addition.isAdding)
    }

    func test_additionShowsLoadingUntilEveryPageIsLoadedThenCommitsOnce() async {
        let addition = NPlaylistAddition()
        var committed: [AudioTrack] = []
        var calls = 0
        let success = await addition.add(load: {
            XCTAssertTrue(addition.isAdding)
            let duplicate = await addition.add(load: { XCTFail("Duplicate operation"); return [] }, commit: { _ in })
            XCTAssertFalse(duplicate)
            return [self.track("a"), self.track("a"), self.track("b")]
        }, commit: {
            XCTAssertTrue(addition.isAdding)
            calls += 1
            committed = $0
        })
        XCTAssertTrue(success)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(committed.map(\.remoteUniqueId), ["a", "b"])
        XCTAssertFalse(addition.isAdding)
    }

    func test_cancelAfterFetchDoesNotCommitAndAllowsRetry() async {
        let addition = NPlaylistAddition()
        var committed = false
        let task = Task {
            await addition.add(load: {
                withUnsafeCurrentTask { $0?.cancel() }
                return [self.track("a")]
            }, commit: { _ in committed = true })
        }
        let cancelled = await task.value
        XCTAssertFalse(cancelled)
        XCTAssertFalse(committed)
        XCTAssertNil(addition.error)
        let retried = await addition.add(load: { [self.track("b")] }, commit: { _ in committed = true })
        XCTAssertTrue(retried)
        XCTAssertTrue(committed)
    }
    func test_emptySelectionDoesNotCreateOrModifyPlaylist() async {
        let addition = NPlaylistAddition()
        let success = await addition.add(load: { [] }, commit: { _ in XCTFail("Empty playlist mutation") })
        XCTAssertFalse(success)
        XCTAssertNotNil(addition.error)
    }

    func test_destinationFailureKeepsPickerAvailableForRetry() async {
        let addition = NPlaylistAddition()
        let success = await addition.add(load: { [self.track("a")] }, commit: { _ in
            throw TelegramError.backend("Destination unavailable")
        })
        XCTAssertFalse(success)
        XCTAssertFalse(addition.isAdding)
        XCTAssertNotNil(addition.error)
        let retried = await addition.add(load: { [self.track("a")] }, commit: { _ in })
        XCTAssertTrue(retried)
        XCTAssertNil(addition.error)
    }

}

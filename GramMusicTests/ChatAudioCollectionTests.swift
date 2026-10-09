import XCTest
@testable import GramMusic

@MainActor
final class ChatAudioCollectionTests: XCTestCase {
    private func tracks(_ count: Int) -> [AudioTrack] {
        (1...count).reversed().map {
            AudioTrack(chatId: 1, messageId: Int64($0), fileId: $0,
                       remoteUniqueId: "track-\($0)", title: "Track", performer: "", duration: 1)
        }
    }

    func test_fullChatIncludesTracksBeyondTheVisiblePage() async throws {
        let source = tracks(235)
        var requests: [Int64] = []
        var counts: [Int] = []
        let full = try await ChatAudioCollection.load(fetchPage: { cursor in
            requests.append(cursor)
            if cursor == 0 { return Array(source.prefix(100)) }
            let start = try XCTUnwrap(source.firstIndex { $0.messageId == cursor })
            return Array(source.dropFirst(start).prefix(100))
        }, progress: { counts.append($0) })
        XCTAssertEqual(full.map(\.id), source.map(\.id))
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(counts, [100, 199, 235])
    }

    func test_pageCallbackReceivesOnlyFreshTracksInTraversalOrder() async throws {
        let source = tracks(3)
        var pages: [[String]] = []
        _ = try await ChatAudioCollection.load(fetchPage: { cursor in
            cursor == 0 ? [source[0], source[1]] : [source[1], source[2]]
        }, onPage: { pages.append($0.map(\.id)) })
        XCTAssertEqual(pages, [[source[0].id, source[1].id], [source[2].id]])
    }

    func test_shortPageDoesNotPrematurelyEndTraversal() async throws {
        let source = tracks(3)
        let full = try await ChatAudioCollection.load { cursor in
            switch cursor {
            case 0: return [source[0]]
            case 3: return [source[1]]
            case 2: return [source[2]]
            default: return []
            }
        }
        XCTAssertEqual(full.map(\.id), source.map(\.id))
    }

    func test_pageFailureDoesNotReturnAPartialChat() async {
        do {
            _ = try await ChatAudioCollection.load { cursor in
                if cursor == 0 { return self.tracks(3) }
                throw TelegramError.backend("Connection lost")
            }
            XCTFail("A partial chat must not be presented as full-chat shuffle")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Connection lost")
        }
    }

    func test_cancellationStopsBeforeAnotherPage() async {
        var requests = 0
        let task = Task { @MainActor in
            try await ChatAudioCollection.load { _ in
                requests += 1
                try await Task.sleep(for: .seconds(30))
                return self.tracks(3)
            }
        }
        await Task.yield()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled shuffle must not produce a queue")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertLessThanOrEqual(requests, 1)
        }
    }
}

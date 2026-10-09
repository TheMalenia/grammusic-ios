import XCTest
@testable import GramMusic

final class BotAudioFileDownloadTests: XCTestCase {
    private func withFiles(_ test: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(directory.appendingPathComponent("incoming"), directory.appendingPathComponent("tdlib/audio"))
    }

    private func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com/audio")!, statusCode: status,
                        httpVersion: nil, headerFields: nil)!
    }

    func test_installsAudioInTDLibDestinationWithoutRelyingOnFileExtension() throws {
        try withFiles { incoming, destination in
            let bytes = Data("ID3".utf8) + Data(repeating: 0, count: 32)
            try bytes.write(to: incoming)
            try BotAudioFileDownload.install(temporaryFile: incoming, response: response(status: 200), to: destination)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
        }
    }

    func test_httpFailureAndHTMLNeverBecomeCachedAudio() throws {
        try withFiles { incoming, destination in
            try Data("ID3".utf8).write(to: incoming)
            XCTAssertThrowsError(try BotAudioFileDownload.install(temporaryFile: incoming, response: response(status: 403), to: destination))
            try Data("<html>Log in to get this song</html>".utf8).write(to: incoming)
            XCTAssertThrowsError(try BotAudioFileDownload.install(temporaryFile: incoming, response: response(status: 200), to: destination))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func test_unsupportedAudioFailsClearlyInsteadOfStartingPlayback() throws {
        try withFiles { incoming, destination in
            try (Data("OggS".utf8) + Data(repeating: 0, count: 32)).write(to: incoming)
            XCTAssertThrowsError(try BotAudioFileDownload.install(temporaryFile: incoming, response: response(status: 200), to: destination)) { error in
                guard case TelegramError.unsupportedFormat = error else { return XCTFail("Expected unsupported audio notice") }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }
}

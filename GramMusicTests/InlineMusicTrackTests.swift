import XCTest
import SwiftData
#if canImport(TDLibKit)
import TDLibKit
#endif
@testable import GramMusic

@MainActor
final class InlineMusicTrackTests: XCTestCase {
    private func track(_ id: String) -> AudioTrack {
        AudioTrack(chatId: 0, messageId: 0, fileId: 123, remoteUniqueId: id,
                   remoteFileId: "persistent-" + id, title: "Song", performer: "Artist", duration: 100,
                   fileName: "song.mp3", mimeType: "audio/mpeg")
    }

    func test_bulkSelectionAndPlaylistRehydrationKeepInlineAudioPlayable() throws {
        let container = try ModelContainer(for: Playlist.self, TrackRef.self,
                                            configurations: .init(isStoredInMemoryOnly: true))
        let service = PlaylistService(context: container.mainContext)
        let tracks = [track("a"), track("b"), track("a")]
        let selection = NTrackSelection()
        selection.begin(tracks[0]); selection.selectAll(tracks)
        let playlist = service.create(name: "Bot discoveries")
        service.add(selection.selected(from: tracks), to: playlist)
        try container.mainContext.save()
        let restored = playlist.orderedTracks.map(\.audioTrack)
        XCTAssertEqual(restored.map(\.remoteUniqueId), ["a", "b"])
        XCTAssertEqual(Set(restored.map(\.id)).count, 2, "Message-less tracks need distinct row identities")
        XCTAssertEqual(restored.map(\.remoteFileId), ["persistent-a", "persistent-b"])
        XCTAssertTrue(restored.allSatisfy { $0.chatId == 0 && $0.messageId == 0 && $0.fileId == -1 })
        XCTAssertEqual(restored.first?.mimeType, "audio/mpeg")
    }

    func test_queueAndCodableRestoreKeepRemoteReferenceWithoutChatMessage() throws {
        let player = PlayerEngine(fileProvider: { _ in URL(fileURLWithPath: "/dev/null") })
        defer { player.stop() }
        player.addToQueue(track("a"))
        XCTAssertEqual(player.queue.first?.remoteFileId, "persistent-a")
        let decoded = try JSONDecoder().decode(AudioTrack.self, from: JSONEncoder().encode(track("a")))
            .rehydratedForOfflineResolution()
        XCTAssertEqual(decoded.fileId, -1)
        XCTAssertEqual(decoded.remoteFileId, "persistent-a")
    }

    #if canImport(TDLibKit)
    private func audio(remoteID: String = "persistent", uniqueID: String = "unique", fileID: Int = 123) -> TDLibKit.Audio {
        let local = LocalFile(canBeDeleted: false, canBeDownloaded: true, downloadOffset: 0,
                              downloadedPrefixSize: 0, downloadedSize: 0, isDownloadingActive: false,
                              isDownloadingCompleted: false, path: "")
        let remote = RemoteFile(id: remoteID, isUploadingActive: false, isUploadingCompleted: true,
                                uniqueId: uniqueID, uploadedSize: 100)
        return TDLibKit.Audio(albumCoverMinithumbnail: nil, albumCoverThumbnail: nil,
                              audio: TDLibKit.File(expectedSize: 100, id: fileID, local: local, remote: remote, size: 100),
                              duration: 150, externalAlbumCovers: [], fileName: "song.mp3", mimeType: "audio/mpeg",
                              performer: "Artist", title: "Song")
    }

    func test_tdlibInlineMappingRetainsAudioMetadataAndPersistentFileReference() throws {
        let mapped = try XCTUnwrap(TDLibTelegramBackend.mapInlineAudio(audio()))
        XCTAssertEqual(mapped.remoteUniqueId, "unique")
        XCTAssertEqual(mapped.remoteFileId, "persistent")
        XCTAssertEqual(mapped.fileId, 123)
        XCTAssertEqual(mapped.chatId, 0)
        XCTAssertEqual(mapped.messageId, 0)
        XCTAssertEqual(mapped.performer, "Artist")
        XCTAssertEqual(mapped.duration, 150)
    }

    func test_urlBackedAudioHasStableDistinctIdentityBeforeDownload() throws {
        let one = try XCTUnwrap(TDLibTelegramBackend.mapInlineAudio(audio(remoteID: "https://example.com/a.mp3", uniqueID: "")))
        let same = try XCTUnwrap(TDLibTelegramBackend.mapInlineAudio(audio(remoteID: "https://example.com/a.mp3", uniqueID: "", fileID: 456)))
        let other = try XCTUnwrap(TDLibTelegramBackend.mapInlineAudio(audio(remoteID: "https://example.com/b.mp3", uniqueID: "")))
        XCTAssertEqual(one.id, same.id)
        XCTAssertNotEqual(one.id, other.id)
        XCTAssertEqual(one.remoteFileId, "https://example.com/a.mp3")
    }

    func test_audioDocumentsArePlayableButUnrelatedDocumentsAreNot() {
        let file = audio().audio
        let song = TDLibKit.Document(document: file, fileName: "song.mp3", mimeType: "application/octet-stream", minithumbnail: nil, thumbnail: nil)
        let pdf = TDLibKit.Document(document: file, fileName: "book.pdf", mimeType: "application/pdf", minithumbnail: nil, thumbnail: nil)
        XCTAssertEqual(TDLibTelegramBackend.mapInlineDocument(song, title: "Song")?.remoteFileId, "persistent")
        XCTAssertNil(TDLibTelegramBackend.mapInlineDocument(pdf, title: "Book"))
    }

    func test_unresolvableInlineAudioIsNotOfferedAsPlayable() {
        XCTAssertNil(TDLibTelegramBackend.mapInlineAudio(audio(remoteID: "")))
        XCTAssertNil(TDLibTelegramBackend.mapInlineAudio(audio(uniqueID: "")))
        XCTAssertNil(TDLibTelegramBackend.mapInlineAudio(audio(fileID: 0)))
    }
    #endif
}

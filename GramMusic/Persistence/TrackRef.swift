import Foundation
import SwiftData

/// A persisted reference to a Telegram audio message inside a playlist.
///
/// We store the *reference* plus cached metadata (so lists render offline) — never the
/// audio bytes. `remoteUniqueId` is the stable handle; `fileId` is session-scoped and
/// re-resolved at play time, so it is intentionally not persisted.
@Model
final class TrackRef {
    var chatId: Int64
    var messageId: Int64
    var remoteUniqueId: String
    var remoteFileId: String = ""
    var title: String
    var performer: String
    var duration: Int
    var fileName: String?
    /// Telegram-reported MIME (e.g. "audio/mpeg") — used to pick a file extension for
    /// AVFoundation when the downloaded file is named without one. Optional so existing
    /// stores migrate automatically.
    var mimeType: String?
    @Attribute(.externalStorage) var artworkData: Data?
    var order: Int
    var addedAt: Date

    var playlist: Playlist?

    init(track: AudioTrack, order: Int) {
        self.chatId = track.chatId
        self.messageId = track.messageId
        self.remoteUniqueId = track.remoteUniqueId
        self.remoteFileId = track.remoteFileId
        self.title = track.title
        self.performer = track.performer
        self.duration = track.duration
        self.fileName = track.fileName
        self.mimeType = track.mimeType
        self.artworkData = track.artworkData
        self.order = order
        self.addedAt = .now
    }

    /// Rehydrate into an `AudioTrack`. `fileId` is unknown until re-resolved via Telegram,
    /// so it starts at -1; the player asks the backend to resolve the real file by
    /// `remoteUniqueId` / message at play time.
    var audioTrack: AudioTrack {
        AudioTrack(
            chatId: chatId,
            messageId: messageId,
            fileId: -1,
            remoteUniqueId: remoteUniqueId,
            remoteFileId: remoteFileId,
            title: title,
            performer: performer,
            duration: duration,
            fileName: fileName,
            mimeType: mimeType,
            artworkData: artworkData
        )
    }
}

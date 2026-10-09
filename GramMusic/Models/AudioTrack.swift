import Foundation

/// A playable audio item that lives in a Telegram message.
///
/// `fileId` is a TDLib *local* file id — valid only for the current session — and is
/// what you pass to `downloadFile`. `remoteUniqueId` is stable across sessions and is
/// what playlists persist so a track can be re-resolved later.
struct AudioTrack: Identifiable, Hashable, Sendable, Codable {
    let chatId: Int64
    let messageId: Int64
    /// TDLib *local* file id — valid only this session. Reset to -1 on any track restored from
    /// persistence so it re-resolves offline via `remoteFileId` (see `rehydratedForOfflineResolution`).
    var fileId: Int
    let remoteUniqueId: String
    /// Persistent remote file id (TDLib `RemoteFile.id`) — resolvable offline via
    /// `getRemoteFile`, so downloaded tracks play without re-fetching the message.
    var remoteFileId: String = ""
    let title: String
    let performer: String
    let duration: Int          // seconds
    /// Unix timestamp (seconds) of the source Telegram message, used to order "New in your chats"
    /// by genuine recency across chats. Optional so it `decodeIfPresent`s — state persisted before
    /// this field existed (recently-played, saved queue, caches) still decodes instead of throwing.
    var date: Int? = nil
    var fileName: String? = nil
    /// Telegram-reported MIME (e.g. "audio/mpeg"). Used to pick a file extension for
    /// AVFoundation when the on-disk file has none. Optional for back-compat with state
    /// persisted before this field existed.
    var mimeType: String? = nil
    var artworkData: Data?

    /// Stable within a session; combines chat + message. Profile-audio tracks aren't tied to a
    /// message (`chatId`/`messageId` are 0) so they fall back to the stable `remoteUniqueId`,
    /// which keeps them distinct in `Identifiable` lists instead of all colliding on "0:0".
    var id: String { chatId == 0 && messageId == 0 ? remoteUniqueId : "\(chatId):\(messageId)" }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let fileName, !fileName.isEmpty { return fileName }
        return "Unknown title"
    }

    var displaySubtitle: String {
        performer.isEmpty ? "Unknown artist" : performer
    }

    var formattedDuration: String {
        let m = duration / 60, s = duration % 60
        return String(format: "%d:%02d", m, s)
    }

    /// A cheap, pre-download guess that this is a container AVFoundation can't decode
    /// (Opus/Ogg, Matroska/WebM) — read from the file-name extension or MIME type. Authoritative
    /// detection still needs the file's magic bytes (`AudioFormat.sniff`), but Telegram audio
    /// reliably carries an `audio/ogg` MIME, so this is good enough to signpost a row *before*
    /// the user taps it. Drives the dimmed "Unsupported" marker in `TrackRow`.
    var isLikelyUnsupported: Bool {
        if let ext = (fileName as NSString?)?.pathExtension,
           let format = AudioFormat(fileExtension: ext),
           !format.isPlayableByAVFoundation { return true }
        switch mimeType?.lowercased() {
        case "audio/ogg", "audio/opus", "audio/x-opus+ogg", "audio/vorbis",
             "audio/webm", "video/webm", "audio/x-matroska", "video/x-matroska":
            return true
        default:
            return false
        }
    }

    /// Copy with replaced artwork (used when a higher-res cover arrives).
    func withArtwork(_ data: Data?) -> AudioTrack {
        var copy = self
        copy.artworkData = data
        return copy
    }

    /// A copy with the session-scoped `fileId` reset to -1, so a track restored from persistence
    /// re-resolves offline via `remoteFileId` instead of trusting a stale local id from the last
    /// launch. The single home for that invariant — used by every restore path (recently-played,
    /// the saved queue).
    func rehydratedForOfflineResolution() -> AudioTrack {
        var copy = self
        copy.fileId = -1
        return copy
    }
}

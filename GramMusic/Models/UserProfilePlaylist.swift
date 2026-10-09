import Foundation

/// A representation of a Telegram user's profile music (their personal playlist on their Telegram profile).
struct UserProfilePlaylist: Identifiable, Hashable, Sendable, Codable {
    let userId: Int64
    let chatId: Int64
    let userName: String
    var photoData: Data?
    var photoId: String?
    var tracks: [AudioTrack]

    var title: String {
        let trimmed = userName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Playlists" }
        if trimmed.hasSuffix("s") || trimmed.hasSuffix("S") {
            return "\(trimmed)' Playlists"
        } else {
            return "\(trimmed)'s Playlists"
        }
    }

    var trackCount: Int { tracks.count }
    var pinKey: String { "u:\(userId)" }
    var id: String { "u:\(userId)" }

    static func == (lhs: UserProfilePlaylist, rhs: UserProfilePlaylist) -> Bool {
        lhs.userId == rhs.userId && lhs.tracks == rhs.tracks && lhs.userName == rhs.userName
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(userId)
        hasher.combine(userName)
        hasher.combine(tracks.count)
    }
}

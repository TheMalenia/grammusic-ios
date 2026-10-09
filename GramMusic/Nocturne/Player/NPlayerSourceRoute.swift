import Foundation

/// A source badge destination that should open inside the app's shared Library navigation stack.
enum NPlayerSourceRoute: Hashable {
    case chat(TelegramChat)
    case profile(UserProfilePlaylist)
    case ownProfile

    static func resolve(track: AudioTrack, contextName: String?, chats: [TelegramChat],
                        profiles: [UserProfilePlaylist], isOwnProfileAudio: Bool) -> NPlayerSourceRoute? {
        if contextName == "Your Profile" || contextName == "Profile Music" {
            return .ownProfile
        }
        if let profile = profiles.first(where: { contextName == $0.title }) {
            return .profile(profile)
        }
        if let chat = chats.first(where: { $0.id == track.chatId }) {
            return .chat(chat)
        }
        if let profile = profiles.first(where: {
            ($0.chatId != 0 && $0.chatId == track.chatId) ||
            $0.tracks.contains(where: { $0.remoteUniqueId == track.remoteUniqueId })
        }) {
            return .profile(profile)
        }
        return isOwnProfileAudio ? .ownProfile : nil
    }
}

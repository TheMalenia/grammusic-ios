import SwiftUI

/// A cover: the real image when present, else the seeded fallback (the theme's artwork
/// style). Square or circle. (Components §Artwork.)
struct Artwork: View {
    @Environment(\.theme) private var theme
    var data: Data? = nil
    var seed: String
    var size: CGFloat = 48
    var kind: SeededArtwork.Kind = .track
    var circle: Bool = false
    var isLowQuality: Bool = false

    private var radius: CGFloat { circle ? size / 2 : (size <= 64 ? 13 : max(8, size * 0.16)) }

    var body: some View {
        Group {
            if let data, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .blur(radius: isLowQuality ? max(4, size * 0.04) : 0)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay {
                        if isLowQuality {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(Color.black.opacity(0.22))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    }
            } else {
                SeededArtwork(seed: seed, style: theme.artwork, kind: kind, size: size, circle: circle)
            }
        }
    }
}

/// Track cover that resolves the *real* album art on demand. Uses the embedded thumbnail
/// when present, otherwise asks `TelegramService` for the cached hi-res cover (this also
/// covers rehydrated recently-played tracks, whose `artworkData` is dropped on persist).
/// Softens low-res provisional thumbnails with a gentle blur only when confirmed to be low-quality.
struct TrackArtwork: View {
    @Environment(TelegramService.self) private var telegram
    let track: AudioTrack
    var size: CGFloat = 48
    var kind: SeededArtwork.Kind = .track
    var circle: Bool = false

    @State private var fetched: Data?
    @State private var isConfirmedLowQuality: Bool = false

    private var isDownloaded: Bool { telegram.isDownloaded(track) }

    var body: some View {
        Artwork(data: fetched ?? track.artworkData, seed: track.remoteUniqueId,
                size: size, kind: kind, circle: circle,
                isLowQuality: isConfirmedLowQuality && !isDownloaded)
            .animation(.easeInOut(duration: 0.25), value: isConfirmedLowQuality)
            .task(id: ArtKey(id: track.remoteUniqueId, downloaded: isDownloaded)) {
                // This view instance is reused across track changes (e.g. the mini-player),
                // so `fetched` may still hold the *previous* track's cover. Clear it before
                // resolving the new one — otherwise the stale image lingers.
                fetched = nil
                isConfirmedLowQuality = false
                let result = await telegram.artworkResult(for: track)
                fetched = result.data
                // Only mark as low quality once resolution completes and confirms there is no high-res art
                isConfirmedLowQuality = (result.data != nil && !result.isHighRes && !telegram.isDownloaded(track))
            }
    }

    private struct ArtKey: Equatable {
        let id: String
        let downloaded: Bool
    }
}

/// Playlist cover that resolves the *high-res* art of its representative track (the first
/// track that carries any cover), analogous to `TrackArtwork`. The embedded minithumbnail is
/// tiny and blurry, so we upgrade it to the cached hi-res cover the moment it lands. Falls back
/// to the seeded gradient keyed on the playlist name. Smart playlists are drawn by the caller
/// (accent-gradient glyph cover), so this is only used for user playlists.
struct PlaylistArtwork: View {
    @Environment(TelegramService.self) private var telegram
    let playlist: Playlist
    var size: CGFloat = 196
    var kind: SeededArtwork.Kind = .playlist

    @State private var fetched: Data?

    /// `orderedTracks` sorts the whole SwiftData relationship, and `$0.audioTrack` builds a fresh
    /// `AudioTrack` struct per ref — for a playlist whose refs carry no inline thumbnail that was
    /// a sort plus one construction per ref, on every render of every playlist row.
    private var repTrack: AudioTrack? {
        let refs = playlist.tracks
        if let withArt = refs.first(where: { $0.artworkData != nil }) { return withArt.audioTrack }
        return refs.min(by: { $0.order < $1.order })?.audioTrack
    }

    var body: some View {
        if let coverData = playlist.coverImageData {
            // User-chosen cover — always wins.
            Artwork(data: coverData, seed: playlist.name, size: size, kind: kind)
        } else {
            let track = repTrack
            Artwork(data: track?.artworkData ?? fetched, seed: playlist.name, size: size, kind: kind)
                .task(id: track?.remoteUniqueId) {
                    guard let track, track.artworkData == nil, fetched == nil else { return }
                    fetched = await telegram.highResArtwork(for: track)
                }
        }
    }
}

/// Chat/channel avatar that resolves the *full-res* profile photo on demand (the chat list
/// only carries a tiny blurred minithumbnail). Uses the big photo when fetched, else the
/// minithumbnail, else the seeded fallback.
struct NChatAvatar: View {
    @Environment(\.theme) private var theme
    @Environment(TelegramService.self) private var telegram
    let chat: TelegramChat
    var size: CGFloat = 52
    var circle: Bool = false

    @State private var hi: Data?
    private var radius: CGFloat { circle ? size / 2 : (size <= 64 ? 13 : max(8, size * 0.16)) }

    var body: some View {
        if chat.kind == .savedMessages {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(theme.accent.fillGradient)
                .overlay {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                }
        } else {
            Artwork(data: hi ?? chat.photoData, seed: chat.title, size: size,
                    kind: .chat, circle: circle)
                .onChange(of: chat.photoId) { _, _ in hi = nil }
                .task(id: chat.photoId) { hi = await telegram.chatPhotoData(for: chat) }
        }
    }
}

/// Profile avatar for a user's Telegram profile playlist (styled as a rounded rectangle matching chats).
struct NProfileAvatar: View {
    @Environment(TelegramService.self) private var telegram
    let profile: UserProfilePlaylist
    var size: CGFloat = 52
    var circle: Bool = false

    @State private var hi: Data?

    var body: some View {
        Artwork(data: hi ?? profile.photoData, seed: profile.userName, size: size,
                kind: .artist, circle: circle)
            .onChange(of: profile.photoId) { _, _ in hi = nil }
            .task(id: profile.photoId ?? "\(profile.userId)") {
                hi = await telegram.profilePhotoData(for: profile)
            }
    }
}

/// Circular artist avatar: a real cover from one of the artist's tracks (chosen once and
/// cached by `TelegramService`), falling back to the seeded gradient-initials circle.
struct NArtistAvatar: View {
    @Environment(TelegramService.self) private var telegram
    let name: String
    var size: CGFloat = 52

    @State private var art: Data?

    var body: some View {
        Artwork(data: art ?? telegram.quickArtistArtwork(for: name), seed: name, size: size, kind: .artist, circle: true)
            .task(id: name) {
                if art == nil {
                    art = await telegram.artistArtwork(for: name)
                }
            }
    }
}

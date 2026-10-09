import Foundation

/// An immutable view of everything `RecipeSelector` is allowed to pick from.
///
/// It is a plain value with no reference to `TelegramService`, `PlaylistService`, SwiftData or the
/// network — which is the point. Selection is the part of this feature that decides what the user
/// actually hears, so it must be testable by handing it a literal, with no backend, no main actor
/// and no simulator. The wiring that fills a snapshot from live services lives at the call site.
struct LibrarySnapshot: Sendable {

    /// Followed artist names, in the user's own order.
    var artists: [String] = []

    /// Imported chats, in the user's own order.
    var chats: [Chat] = []

    /// Tracks keyed by performer name (matched case-insensitively via `TextMatch`).
    var tracksByArtist: [String: [AudioTrack]] = [:]

    /// Tracks keyed by chat id.
    var tracksByChat: [Int64: [AudioTrack]] = [:]

    var favorites: [AudioTrack] = []
    var downloaded: [AudioTrack] = []

    /// Most-recent first, as `TelegramService` keeps it.
    var recentlyPlayed: [AudioTrack] = []

    /// `remoteUniqueId` → lifetime play count.
    var playCounts: [String: Int] = [:]

    struct Chat: Sendable, Equatable {
        let id: Int64
        let title: String
        /// A one-to-one chat, whose title is *a person's name*. Kept in the snapshot so local
        /// selection still works if the user names it, but withheld from the roster — see
        /// `roster`.
        var isPrivate: Bool = false
    }

    /// Every track the snapshot knows about, de-duplicated. The `.everything` scope's pool.
    var allTracks: [AudioTrack] {
        var seen = Set<String>()
        var out: [AudioTrack] = []
        for group in [Array(tracksByChat.values), Array(tracksByArtist.values)].flatMap({ $0 }) {
            for track in group where seen.insert(track.remoteUniqueId).inserted {
                out.append(track)
            }
        }
        for track in favorites + downloaded + recentlyPlayed
        where seen.insert(track.remoteUniqueId).inserted {
            out.append(track)
        }
        return out
    }

    /// The names a **Composer** is shown, so it can only ever name things that exist.
    ///
    /// **Private chats are excluded**, because their titles are people's names and a Composer may
    /// be a third-party model behind a network call. Group and channel titles are content the
    /// user chose to follow; a contact's name is not. Excluding them here rather than from
    /// `chats` keeps them locally selectable — if the user types the name themselves, the
    /// on-device selector still finds it, but it is never volunteered to a model.
    /// (Secret chats never reach the snapshot at all — see `live`.)
    var roster: ComposerRoster {
        ComposerRoster(artists: artists,
                       chats: chats.filter { !$0.isPrivate }.map(\.title))
    }
}

import Foundation

/// The names a **Composer** is allowed to refer to.
///
/// Handing over the roster is what keeps a Composer honest: it is asked to pick from a list, not
/// to recall the user's library from thin air. It's also the whole context budget for a
/// model-backed Composer, so it stays names-only — never ids, never `remoteUniqueId`s, never chat
/// ids. Nothing in a roster identifies a Telegram account.
struct ComposerRoster: Sendable, Equatable {
    var artists: [String] = []
    var chats: [String] = []

    /// Cap the roster before it reaches a model with a finite context window. Order is the user's
    /// own (pinned/recent first), so truncation drops the least relevant names.
    func capped(artists artistLimit: Int = 60, chats chatLimit: Int = 60) -> ComposerRoster {
        ComposerRoster(artists: Array(artists.prefix(artistLimit)),
                       chats: Array(chats.prefix(chatLimit)))
    }

    var isEmpty: Bool { artists.isEmpty && chats.isEmpty }
}

/// What a **Composer** returns for one user message.
struct ComposerReply: Sendable, Equatable {
    /// A sentence to show in the chat, in the app's voice.
    var reply: String

    /// The structured request, when the Composer understood one. `nil` means it needs more from
    /// the user before anything can be built.
    var recipe: PlaylistRecipe?

    /// Set when the Composer wants one specific thing clarified ("Did you mean LoFi Beats HQ?").
    /// Distinct from a `nil` recipe: here we *did* understand the shape, we're unsure of a name.
    var clarification: String?

    static func needsMore(_ reply: String) -> ComposerReply {
        ComposerReply(reply: reply, recipe: nil, clarification: nil)
    }
}

/// Turns a natural-language request into a `PlaylistRecipe`.
///
/// The seam that makes the provider a detail. `HeuristicComposer` needs no network; a
/// model-backed Composer will need a proxy and a key. Both satisfy this protocol, so swapping one
/// for the other — or falling back from the second to the first when a quota is exhausted or the
/// device is offline — touches no other file. Nothing downstream of here knows or cares which ran.
protocol PlaylistComposer: Sendable {
    /// - Parameters:
    ///   - request: exactly what the user typed.
    ///   - roster: the names that exist, so the reply can only refer to real ones.
    func compose(_ request: String, roster: ComposerRoster) async throws -> ComposerReply
}

/// Why a Composer couldn't answer. Split along the same line as `TelegramError`: a `.transient`
/// failure is worth another try (and worth falling back to `HeuristicComposer` for right now),
/// while `.unusable` means the request itself won't get better by repeating it.
enum ComposerError: Error, Equatable {
    /// Network down, rate limited, provider 5xx, request cancelled.
    case transient(String)
    /// The request made no sense, or the provider returned something unparseable.
    case unusable(String)
}

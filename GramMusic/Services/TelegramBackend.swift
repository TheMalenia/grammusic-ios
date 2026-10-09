import Foundation
import AVFoundation

/// Information about how the verification code was delivered and expected length/timeout.
struct TelegramCodeInfo: Equatable, Sendable {
    var length: Int = 5
    var timeout: Int = 60
    var typeDescription: String = "Telegram app"
    var isTelegramApp: Bool = true
}

/// Where the user is in the Telegram login flow.
enum TelegramAuthState: Equatable, Sendable {
    case initializing
    case waitingForPhoneNumber
    case waitingForCode(codeInfo: TelegramCodeInfo? = nil)
    case waitingForPassword(hint: String? = nil)     // 2FA / cloud password
    case ready
    case loggingOut
    case closed

    var isWaitingForCode: Bool {
        if case .waitingForCode = self { return true }
        return false
    }

    var isWaitingForPassword: Bool {
        if case .waitingForPassword = self { return true }
        return false
    }

    var passwordHint: String? {
        if case .waitingForPassword(let hint) = self { return hint }
        return nil
    }

    var codeInfo: TelegramCodeInfo? {
        if case .waitingForCode(let info) = self { return info }
        return nil
    }
}

/// TDLib network/connection state, surfaced for a status indicator.
enum TelegramConnectionState: Equatable, Sendable {
    case waitingForNetwork
    case connecting
    case updating
    case ready

    /// Banner text while not fully connected; `nil` when ready (hide the banner).
    var label: String? {
        switch self {
        case .ready: nil
        case .waitingForNetwork: "Waiting for network…"
        case .connecting: "Connecting…"
        case .updating: "Updating…"
        }
    }
}

/// Minimal profile of the logged-in user, shown in the Settings header.
struct TelegramAccount: Equatable, Sendable {
    var name: String
    var phone: String
    var username: String?
    var photo: Data?
}

/// A download-progress update for one audio track's file, keyed by the stable `remoteUniqueId`.
/// The backend emits these only for *audio tracks* it is fetching (not avatars/thumbnails), so
/// the service can drive the per-row filling-circle and mark a track downloaded on completion.
struct TrackDownloadProgress: Sendable {
    let remoteUniqueId: String
    /// Downloaded fraction, 0…1.
    let fraction: Double
    let isComplete: Bool
    /// Size of the file on disk, in bytes. Carried on the update because the cache ledger has to
    /// bill the bytes against its budget the moment a file completes, and a completion event is
    /// the only signal for a track that was merely *streamed* — there is no URL to stat.
    var bytes: Int64 = 0
}

/// A real-time update for a message in a chat.
enum MessageUpdate: Sendable {
    case new(ChatMessage)
    case edited(ChatMessage)
    case deleted([Int64])
}

enum TelegramError: LocalizedError {
    case notReady
    case missingCredentials
    case backend(String)
    /// A failure that is very likely to work on a second attempt — a dropped connection, a request
    /// that timed out, a TDLib 5xx, a stalled download. Carries the same user-facing text as
    /// `.backend`, but `Retry` is allowed to swallow it and try again rather than surface it.
    /// **This distinction is the whole point:** a wrong verification code must be shown at once,
    /// while a request lost to a flaky link must not be shown at all until we've genuinely failed.
    case transient(String)
    /// The track's real container is one AVFoundation can't decode (Opus/Ogg, Matroska/WebM).
    /// We ship no FFmpeg, so we surface this instead of letting playback fail silently.
    case unsupportedFormat(String)
    /// The track was deleted from Telegram and cannot be streamed or downloaded.
    case deleted(String)

    var errorDescription: String? {
        switch self {
        case .notReady: "Telegram is not connected yet."
        case .missingCredentials: "Telegram API credentials are missing. Add them in Config/Secrets.xcconfig."
        case .backend(let message): message
        case .transient(let message): message
        case .unsupportedFormat(let name): "\(name) audio isn't supported yet."
        case .deleted(let title): title.isEmpty ? "This track was deleted from Telegram." : "\(title) was deleted from Telegram."
        }
    }

    /// Whether another attempt could plausibly succeed. `.notReady` counts: the backend is still
    /// coming up, and by the time the backoff elapses it usually is.
    var isRetryable: Bool {
        switch self {
        case .transient, .notReady: true
        case .missingCredentials, .backend, .unsupportedFormat, .deleted: false
        }
    }

    /// Classify an arbitrary error for the retry layer. Anything we don't recognise is treated as
    /// permanent — retrying a failure we can't reason about just delays the user's bad news.
    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let telegram = error as? TelegramError { return telegram.isRetryable }
        let ns = error as NSError
        switch ns.domain {
        case NSURLErrorDomain:
            return [URLError.timedOut, .cannotConnectToHost, .networkConnectionLost,
                    .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
                    .resourceUnavailable, .internationalRoamingOff, .callIsActive,
                    .dataNotAllowed, .secureConnectionFailed]
                .map(\.rawValue).contains(ns.code)
        case NSPOSIXErrorDomain:
            return true   // ENETDOWN / ECONNRESET / EHOSTUNREACH and friends
        default:
            return false
        }
    }
}

/// The async surface the rest of the app uses to talk to Telegram. Two implementations
/// exist — `MockTelegramBackend` (default, in-memory) and `TDLibTelegramBackend` (real).
/// Keeping this behind a protocol is what lets the app build and run before the heavy
/// TDLib package is resolved.
protocol TelegramBackend: AnyObject, Sendable {
    /// Stream of authorization-state transitions. Emits the current state on subscribe.
    func authStates() -> AsyncStream<TelegramAuthState>

    /// Stream of network/connection-state transitions for the status indicator.
    func connectionStates() -> AsyncStream<TelegramConnectionState>

    /// Stream of audio-track download progress (filling-circle UI + auto-record on completion).
    /// Emits per `remoteUniqueId` for tracks the backend is downloading or streaming.
    func downloadProgress() -> AsyncStream<TrackDownloadProgress>

    /// Kick off the client / restore a saved session.
    func start() async

    func setPhoneNumber(_ phone: String) async throws
    func checkCode(_ code: String) async throws
    func checkPassword(_ password: String) async throws
    func logOut() async throws
    /// Nuke the TDLib database and restart the client from scratch — escapes any stuck
    /// auth flow (e.g. `waitCode` persisted across app restarts).
    func resetAuth() async

    /// The logged-in user's profile (name, phone, @username, small avatar). `nil` if unavailable.
    func currentAccount() async -> TelegramAccount?

    func loadChats(limit: Int) async throws -> [TelegramChat]

    /// Audio files in a chat (most-recent first). Pass the last loaded message id as
    /// `fromMessageId` to page backwards; 0 starts from the newest.
    func audioMessages(in chatId: Int64, limit: Int, fromMessageId: Int64) async throws -> [AudioTrack]

    /// Approximate number of audio messages in a chat (used to hide chats with no music).
    func audioCountAndLastDate(in chatId: Int64) async -> (Int, Date?)

    /// Ensure the track's audio is downloaded locally and return a playable file URL.
    func ensureLocalFile(for track: AudioTrack) async throws -> URL

    /// Delete the track's locally-downloaded file, freeing disk. Best-effort (no-op if absent);
    /// the track can be re-downloaded later. Used by "remove download".
    func removeLocalFile(for track: AudioTrack) async

    /// Stop an in-progress download **without discarding what has already been fetched.**
    ///
    /// The difference from `removeLocalFile` matters: abandoning a track (the user skipped past it,
    /// or closed the player) should stop spending their bandwidth, but throwing the bytes away
    /// means skipping back re-downloads from zero. TDLib keeps the partial file, so this is a pure
    /// "stop chasing it". No-op when the file is already complete or was never started.
    func cancelDownload(for track: AudioTrack) async

    /// The genuinely full-resolution album cover embedded in the audio file — only available
    /// once the file is downloaded to disk. `nil` if the file isn't downloaded yet or carries
    /// no embedded art. This is the *final* cover (never improves further).
    func embeddedArtwork(for track: AudioTrack) async -> Data?

    /// Telegram's small album cover (sender thumbnail / external cover) read from the message.
    /// The best available *before* the file is downloaded; a low-res *provisional* cover that
    /// should be upgraded to `embeddedArtwork` once the file lands. `nil` if unavailable.
    func thumbnailArtwork(for track: AudioTrack) async -> Data?

    /// Lyrics embedded in the downloaded audio file (ID3 `USLT` / MP4 lyrics atom), read via
    /// AVFoundation — may be plain text or LRC with timestamps. Only available once the file is
    /// on disk. `nil` if the file isn't downloaded yet or carries no embedded lyrics.
    func embeddedLyrics(for track: AudioTrack) async -> String?

    /// Full-resolution chat/channel photo (downloads the small avatar file). `nil` if none.
    func chatPhoto(chatId: Int64) async -> Data?

    /// Search audio messages across all of the user's chats.
    func searchAudio(query: String, limit: Int) async throws -> [AudioTrack]
    func searchAudioPage(query: String, offset: String) async throws -> MusicSearchPage

    /// The current user's **profile audio** — the songs shown on their own Telegram profile,
    /// most-recent first. These aren't tied to a chat message, so the returned tracks carry a
    /// `remoteFileId` for offline-capable playback and have `chatId`/`messageId` of 0.
    func profileAudio(limit: Int) async throws -> [AudioTrack]
    func profileAudioPage(offset: Int) async throws -> MusicSearchPage

    /// Fetch profile audio tracks for any specific Telegram user (e.g. contacts/chats).
    func userProfileAudio(userId: Int64, limit: Int) async throws -> [AudioTrack]
    func userProfileAudioPage(userId: Int64, offset: Int) async throws -> MusicSearchPage

    /// Add a track to the **beginning** of the current user's profile audio (writes to Telegram).
    func addProfileAudio(_ track: AudioTrack) async throws

    /// Remove a track from the current user's profile audio (writes to Telegram).
    func removeProfileAudio(_ track: AudioTrack) async throws

    /// Reposition `track` within the profile audio so it sits directly **after** `afterTrack`
    /// (pass `nil` to move it to the beginning). Writes to Telegram.
    func reorderProfileAudio(_ track: AudioTrack, after afterTrack: AudioTrack?) async throws

    /// A playback item for the track. May stream (play while downloading) to avoid waiting
    /// for the whole file; falls back to a fully-downloaded file when streaming isn't possible.
    func makePlayerItem(for track: AudioTrack) async throws -> AVPlayerItem

    /// A playable local file URL resolved with **no network** — for tracks already fully on
    /// disk, so offline playback is instant. `nil` if the file isn't downloaded/resolvable
    /// locally (caller falls back to `makePlayerItem`).
    func localPlayableURL(for track: AudioTrack) async -> URL?

    /// Report a chat or specific messages in a chat. The reporting process is dynamic:
    /// 1. Call this with `optionId: nil, text: nil`. It may return `.optionRequired`.
    /// 2. Prompt the user, then call again with the chosen `optionId`. It may return `.textRequired`.
    /// 3. Prompt for text, call again with `optionId` and `text`. It returns `.ok`.
    func reportChat(chatId: Int64, messageIds: [Int64]?, optionId: Data?, text: String?) async throws -> TelegramReportResult

    /// Block or unblock a message sender on Telegram itself.
    ///
    /// TDLib can only block **users and supergroups**, so `userId` carries the user behind a
    /// private chat / bot when there is one. Channels and groups the user merely follows are not
    /// blockable — `leaveChat` is the equivalent there, and `TelegramService.block(chat:)` picks
    /// between them. Either way the *app-side* block list is what hides the content instantly;
    /// this is the account-level half, which can fail (offline, flood wait) without the block
    /// appearing to do nothing.
    func setSenderBlocked(chatId: Int64, userId: Int64?, blocked: Bool) async throws

    /// Every sender currently on Telegram's block list, as chat ids.
    ///
    /// Telegram is the source of truth for blocking, the same way it is for Profile Music. Without
    /// this the app's local list could only ever grow: someone blocked in GramMusic and then
    /// unblocked *in Telegram* stayed hidden here forever, across relaunches, with no in-app way
    /// back.
    func blockedSenderIds() async throws -> Set<Int64>

    /// Live block/unblock events (`chatId`, whether it is now blocked) — so an unblock performed
    /// in Telegram while GramMusic is open takes effect immediately rather than at the next launch.
    func blockListUpdates() -> AsyncStream<(chatId: Int64, isBlocked: Bool)>

    /// Leave a channel or group — the closest Telegram equivalent of blocking a broadcast source.
    func leaveChat(chatId: Int64) async throws

    /// Chat history for rendering a standard chat view.
    func chatHistory(in chatId: Int64, limit: Int, fromMessageId: Int64) async throws -> [ChatMessage]

    /// Returns true if the user can send messages in the chat
    func canSendMessages(in chatId: Int64) async -> Bool

    /// Send a text message to a chat.
    func sendTextMessage(to chatId: Int64, text: String) async throws

    /// Send an audio track to a chat with an optional caption.
    func sendAudioMessage(to chatId: Int64, track: AudioTrack, caption: String?) async throws

    /// Send a callback query (from tapping an inline bot button).
    func sendBotCallbackQuery(chatId: Int64, messageId: Int64, payload: Data) async throws

    /// Resolve a bot by username to its user ID.
    func resolveBot(username: String) async throws -> Int64

    /// Whether the logged-in user is a member of a public channel (by username, no `@`).
    /// Never throws — a lookup that fails (offline, flood wait) answers `.unknown`, which
    /// callers must read as "don't nag", not as "not a member".
    func channelMembership(username: String) async -> ChannelMembership

    /// Join a public channel by username (no `@`).
    func joinChannel(username: String) async throws
    
    /// Private-chat context for independent music searches; does not send a message.
    func inlineMusicSearchChatId() async throws -> Int64

    /// Get inline query results for a bot.
    func getInlineQueryResults(botUserId: Int64, chatId: Int64, query: String, offset: String) async throws -> AppInlineQueryResults
    
    /// Send an inline query result.
    func sendInlineQueryResultMessage(chatId: Int64, botUserId: Int64, queryId: Int64, resultId: String) async throws

    /// Stream of real-time message updates for a specific chat.
    func messageUpdates(for chatId: Int64) -> AsyncStream<MessageUpdate>

    /// Stream of events indicating messages were deleted anywhere across chats.
    func deletionUpdates() -> AsyncStream<(chatId: Int64, messageIds: [Int64])>

    /// Stream of events indicating the chat list or its sort order has changed.
    func chatListUpdates() -> AsyncStream<ChatListEvent>

    /// Stream of events indicating the logged-in user's own profile (name, photo) has changed.
    func accountUpdates() -> AsyncStream<Void>
}

/// What happened to the chat list.
///
/// This used to be a bare `Void`, and the cost was a real bug: the service rate-limits
/// update-driven refreshes to `chatRefreshTTL` (three minutes) because reloading the list issues
/// one `getChat` per chat. With no payload it could not tell "a contact renamed themselves" from
/// "the user just joined a channel", so a newly joined chat did not appear in the Library until the
/// TTL expired or the app was relaunched. The id lets the service bypass the TTL for exactly the
/// case that must not wait — a chat it has never seen — while everything else stays rate-limited.
enum ChatListEvent: Sendable {
    /// TDLib learned about a chat. Fires in bulk during startup for chats already known, so the
    /// *service* decides whether this id is genuinely new; the backend only reports it.
    case chatAdded(Int64)
    /// Actual new music advances the collection immediately, before the metadata refresh.
    case audioAdded(chatId: Int64, date: Date)
    /// A title, photo, position or new audio message changed something about the existing list.
    case changed
}

/// Membership of the app's own Telegram channel. `.unknown` is a *failed lookup*, kept
/// distinct from `.notMember` so a dropped connection can't make the join prompt appear to
/// someone who already joined.
enum ChannelMembership: Equatable, Sendable {
    case member
    case notMember
    case unknown
}

/// An option presented by Telegram when reporting a chat or message.
struct TelegramReportOption: Identifiable, Sendable {
    let id: Data
    let text: String
}

/// A simplified representation of an inline query result for the UI.
struct AppInlineQueryResult: Identifiable, Sendable {
    let id: String
    let title: String?
    let description: String?
    let type: String
    /// Audio reference for direct playback; nil for articles and other non-audio results.
    var track: AudioTrack? = nil
}

struct AppInlineQueryResults: Sendable {
    let inlineQueryId: Int64
    let botUserId: Int64
    let results: [AppInlineQueryResult]
    var nextOffset: String = ""
}

/// The result of a report operation.
enum TelegramReportResult: Sendable {
    /// The report was successful.
    case ok
    /// The server requires the user to select one of these options.
    case optionRequired(title: String, options: [TelegramReportOption])
    /// The server requires additional text details for this option.
    case textRequired(optionId: Data, isOptional: Bool)
}

// Backends without pagination expose one complete fixture page.
extension TelegramBackend {
    func inlineMusicSearchChatId() async throws -> Int64 {
        guard let saved = try await loadChats(limit: 100).first(where: { $0.kind == .savedMessages }) else {
            throw TelegramError.notReady
        }
        return saved.id
    }

    func profileAudioPage(offset: Int) async throws -> MusicSearchPage {
        MusicSearchPage(tracks: offset == 0 ? try await profileAudio(limit: 100) : [])
    }

    func searchAudioPage(query: String, offset: String) async throws -> MusicSearchPage {
        MusicSearchPage(tracks: offset.isEmpty ? try await searchAudio(query: query, limit: 100) : [])
    }

    func userProfileAudioPage(userId: Int64, offset: Int) async throws -> MusicSearchPage {
        MusicSearchPage(tracks: offset == 0 ? try await userProfileAudio(userId: userId, limit: 100) : [])
    }
}

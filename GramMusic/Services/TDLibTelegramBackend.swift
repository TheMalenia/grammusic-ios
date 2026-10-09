import Foundation
import AVFoundation
import UniformTypeIdentifiers
import CryptoKit
import Network
import os
#if canImport(UIKit)
import UIKit
#endif

#if canImport(TDLibKit)
import TDLibKit

/// Real Telegram backend over TDLib (via TDLibKit).
///
/// NOTE ON API DRIFT: TDLibKit's method signatures are generated from the TDLib TL
/// schema and occasionally shift between TDLib versions (parameter labels/optionality).
/// All TDLib calls are isolated to this file. If the project fails to compile after the
/// package resolves, fix the call sites here using Xcode autocomplete — nothing else in
/// the app needs to change. The pinned version is in project.yml.
final class TDLibTelegramBackend: TelegramBackend, @unchecked Sendable {

    private let manager = TDLibClientManager()

    /// The live TDLib client. It is **replaced** whenever TDLib reaches `.closed` (log out, auth
    /// reset), from a main-actor task, while requests are being issued from arbitrary tasks and
    /// `handle(data:)` runs on TDLib's own callback thread. Guarded by its own lock — deliberately
    /// *not* `lock`, so reading it can never deadlock against code already holding that one.
    private let clientLock = NSLock()
    private var _client: TDLibClient!
    private var client: TDLibClient { clientLock.withLock { _client } }
    private func setClient(_ new: TDLibClient) { clientLock.withLock { _client = new } }

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<TelegramAuthState>.Continuation] = [:]
    private var currentState: TelegramAuthState = .initializing
    private var connContinuations: [UUID: AsyncStream<TelegramConnectionState>.Continuation] = [:]
    private var currentConn: TelegramConnectionState = .connecting
    private var progressContinuations: [UUID: AsyncStream<TrackDownloadProgress>.Continuation] = [:]
    private var chatListContinuations: [UUID: AsyncStream<ChatListEvent>.Continuation] = [:]
    private var blockListContinuations: [UUID: AsyncStream<(chatId: Int64, isBlocked: Bool)>.Continuation] = [:]
    private var accountUpdateContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var deletionContinuations: [UUID: AsyncStream<(chatId: Int64, messageIds: [Int64])>.Continuation] = [:]
    private var messageContinuations: [Int64: [UUID: AsyncStream<MessageUpdate>.Continuation]] = [:]
    /// Maps a TDLib file id to the audio track's stable `remoteUniqueId`, populated whenever we
    /// start downloading/streaming a track's file. Lets `updateFile` (which only carries a file
    /// id) be reported as track progress — and filters out unrelated files (avatars/thumbnails).
    private var generationTasks: [Int64: (token: UUID, task: Task<Void, Never>)] = [:]
    private var trackFileIds: [Int: String] = [:]

    /// Memoised `getMe().id`. `map(chat:)` runs per chat and used to issue a full `getMe()`
    /// round-trip for every private chat just to spot Saved Messages — hundreds of redundant
    /// requests per `loadChats(limit: 1000)`. Cleared whenever the account changes.
    private var cachedSelfId: Int64?

    /// Last progress fraction forwarded per file, so `handleFileUpdate` can drop the flood of
    /// `updateFile` chunk callbacks TDLib emits (tens per second, per file). Every one of them
    /// used to hop to the main actor and invalidate every visible track list.
    private var lastEmittedFraction: [Int: Double] = [:]
    /// When true, the next `.closed` handler will delete the TDLib database before
    /// recreating the client — used by `resetAuth()` to escape stuck auth states.
    private var pendingAuthReset = false


    /// Watches connectivity so we can tell TDLib the network changed. On iOS a running TDLib client
    /// can otherwise sit in `waitingForNetwork` long after the network is back (it only re-detected
    /// on a fresh launch) — `setNetworkType` nudges it to reconnect immediately.
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "grammusic.network.monitor")
    private var lastNetworkType: NetworkType?
    private var lastNetworkNudge = Date.distantPast

    init() {
        _client = manager.createClient { [weak self] data, client in
            self?.handle(data: data, client: client)
        }
        startNetworkMonitor()
        observeForeground()
        Self.clearPlayableHardLinks()
    }

    /// Re-establish TDLib's connections when the app returns to the foreground. This is the reliable
    /// trigger for the "open app, leave to a VPN app, switch a VPN on, come back" flow — where
    /// Telegram was unreachable until the VPN, the interface type never changed, and `NWPathMonitor`
    /// may not have reported the tunnel. Coming back to the app is the cue to force a reconnect.
    /// Retained so `deinit` can unregister it — `addObserver(forName:)` otherwise leaves a live
    /// registration behind for the lifetime of the process.
    private var foregroundObserver: NSObjectProtocol?

    deinit {
        pathMonitor.cancel()
        for entry in generationTasks.values { entry.task.cancel() }
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    private func observeForeground() {
        #if canImport(UIKit)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Only bother if we're not already connected (avoid disrupting a healthy session).
            let connected = self.lock.withLock { self.currentConn == .ready }
            if !connected { self.forceReconnect(self.lock.withLock { self.lastNetworkType } ?? .networkTypeOther) }
        }
        #endif
    }

    /// Force TDLib to drop and re-establish every connection by toggling the network type off→on.
    /// A plain `setNetworkType(sameType)` can be a no-op; the toggle guarantees a fresh reconnect,
    /// which is what actually picks up a newly-enabled VPN route.
    private func forceReconnect(_ type: NetworkType) {
        // `NetworkType` is a TDLibKit generated enum and carries no `Sendable` conformance, so
        // capturing it in a task is a transfer the compiler can't verify. It is a plain value;
        // `Unchecked` is the honest spelling of "I have checked this one".
        let boxed = Unchecked(type)
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.client.setNetworkType(type: .networkTypeNone)
            _ = try? await self.client.setNetworkType(type: boxed.value)
        }
    }

    /// Carries a value the compiler cannot prove `Sendable` across an isolation boundary.
    ///
    /// TDLibKit's types are generated from the TL schema and declare no conformances, so nearly
    /// every one of them is opaque to region-based isolation even when it is a plain immutable
    /// value. Confined to this file, which is already `@unchecked Sendable` for the same reason.
    private struct Unchecked<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let type: NetworkType
            if path.status != .satisfied {
                type = .networkTypeNone
            } else if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
                type = .networkTypeWiFi
            } else if path.usesInterfaceType(.cellular) {
                type = .networkTypeMobile
            } else {
                type = .networkTypeOther
            }
            // Reflect "offline" in the UI immediately; TDLib will confirm `ready` once it reconnects.
            if type == .networkTypeNone { self.transitionConn(.waitingForNetwork) }
            // Decide whether to ping TDLib. `setNetworkType` forces ALL connections to be
            // re-established, so it's the right hammer whenever the route changes — crucially
            // including turning a VPN on/off, where the interface type is UNCHANGED but reachability
            // to Telegram flips (common where Telegram is blocked without a VPN). We always nudge on
            // a genuine type change, and otherwise nudge on any other path change but throttled so we
            // never call it "too often" (TDLib's own warning).
            let shouldNudge: Bool = self.lock.withLock {
                let changed = self.lastNetworkType != type
                self.lastNetworkType = type
                guard type != .networkTypeNone else { return false }   // nothing to reconnect to
                if changed || Date().timeIntervalSince(self.lastNetworkNudge) > 1.5 {
                    self.lastNetworkNudge = Date()
                    return true
                }
                return false
            }
            if shouldNudge { self.forceReconnect(type) }
        }
        pathMonitor.start(queue: pathQueue)
    }

    // MARK: - Auth state stream

    func authStates() -> AsyncStream<TelegramAuthState> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                continuations[id] = continuation
                continuation.yield(currentState)
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    private func transition(_ new: TelegramAuthState) {
        lock.withLock {
            currentState = new
            for c in continuations.values { c.yield(new) }
        }
    }

    // MARK: - Connection state stream

    func connectionStates() -> AsyncStream<TelegramConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                connContinuations[id] = continuation
                continuation.yield(currentConn)
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.connContinuations.removeValue(forKey: id) }
            }
        }
    }

    private func transitionConn(_ new: TelegramConnectionState) {
        lock.withLock {
            currentConn = new
            for c in connContinuations.values { c.yield(new) }
        }
    }

    // MARK: - Download-progress stream

    func downloadProgress() -> AsyncStream<TrackDownloadProgress> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { progressContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.progressContinuations.removeValue(forKey: id) }
            }
        }
    }

    func chatListUpdates() -> AsyncStream<ChatListEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { chatListContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.chatListContinuations.removeValue(forKey: id) }
            }
        }
    }

    /// Fires whenever the logged-in user's own profile changes (name, photo, etc.).
    func accountUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { accountUpdateContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.accountUpdateContinuations.removeValue(forKey: id) }
            }
        }
    }

    /// Register a track's file id so its `updateFile`s are reported as track download progress.
    private func trackFile(_ fileId: Int, for uniqueId: String) {
        lock.withLock { trackFileIds[fileId] = uniqueId }
    }

    private func emitProgress(_ update: TrackDownloadProgress) {
        lock.withLock { for c in progressContinuations.values { c.yield(update) } }
    }

    // MARK: - Update handling

    private func handle(data: Data, client: TDLibClient) {
        guard let update = try? client.decoder.decode(Update.self, from: data) else { return }
        switch update {
        case .updateAuthorizationState(let payload):
            handleAuthState(payload.authorizationState)
        case .updateConnectionState(let payload):
            handleConnectionState(payload.state)
        case .updateFileGenerationStart(let payload):
            startURLGeneration(payload, client: client)
        case .updateFileGenerationStop(let payload):
            lock.withLock { generationTasks.removeValue(forKey: payload.generationId.rawValue) }?.task.cancel()
        case .updateFile(let payload):
            handleFileUpdate(payload.file)
        // Deliberately **not** `.updateUser`: TDLib emits it for every user it learns about —
        // hundreds during initial sync and a steady trickle after — and each one woke a refresh
        // that reloads the entire chat list. A contact renaming themselves or changing their photo
        // arrives as `.updateChatTitle` / `.updateChatPhoto` for their private chat anyway, which
        // is what actually changes a row.
        case .updateNewChat(let payload):
            // Carries the id so the service can bypass its refresh TTL for a chat it has never
            // seen — joining a channel must show up without waiting minutes for the rate limit.
            let id = payload.chat.id
            lock.withLock { for c in chatListContinuations.values { c.yield(.chatAdded(id)) } }
        case .updateChatBlockList(let payload):
            // `blockList == nil` means "no longer blocked" — this is what makes an unblock
            // performed in Telegram reach the app while it is open.
            let isBlocked = payload.blockList != nil
            let chatId = payload.chatId
            lock.withLock {
                for c in blockListContinuations.values { c.yield((chatId: chatId, isBlocked: isBlocked)) }
            }
        case .updateChatPosition, .updateChatTitle, .updateChatPhoto:
            lock.withLock { for c in chatListContinuations.values { c.yield(.changed) } }
        case .updateUserFullInfo:  // own profile changed
            lock.withLock { for c in accountUpdateContinuations.values { c.yield(()) } }
        case .updateNewMessage(let payload):
            if let msg = mapChatMessage(message: payload.message, chatId: payload.message.chatId) {
                let chatId = payload.message.chatId
                lock.withLock {
                    for c in messageContinuations[chatId, default: [:]].values {
                        c.yield(.new(msg))
                    }
                }
                if case .messageAudio = payload.message.content {
                    let date = Date(timeIntervalSince1970: Double(payload.message.date))
                    lock.withLock {
                        for c in chatListContinuations.values { c.yield(.audioAdded(chatId: chatId, date: date)) }
                    }
                }
            }
        case .updateMessageContent(let payload):
            let chatId = payload.chatId
            let messageId = payload.messageId
            // Same reason as `forceReconnect`: hand the task the (thread-safe) client explicitly
            // rather than capturing `self` and reaching back into lock-guarded state.
            nonisolated(unsafe) let client = self.client
            Task { [weak self] in
                guard let msg = try? await client.getMessage(chatId: chatId, messageId: messageId),
                      let self, let mapped = self.mapChatMessage(message: msg, chatId: chatId) else { return }
                self.lock.withLock {
                    for c in self.messageContinuations[chatId, default: [:]].values {
                        c.yield(.edited(mapped))
                    }
                }
            }
        case .updateDeleteMessages(let payload):
            // If messages were only evicted from local cache, they are NOT deleted from Telegram.
            // Only forward deletions if they were permanently deleted by a user.
            guard payload.isPermanent, !payload.fromCache else { break }
            let chatId = payload.chatId
            let ids = payload.messageIds
            lock.withLock {
                for c in messageContinuations[chatId, default: [:]].values {
                    c.yield(.deleted(ids))
                }
                for c in deletionContinuations.values {
                    c.yield((chatId: chatId, messageIds: ids))
                }
            }
        default:
            break
        }
    }

    private func startURLGeneration(_ payload: UpdateFileGenerationStart, client: TDLibClient) {
        let generationID = payload.generationId.rawValue
        let original = payload.originalPath
        let destination = payload.destinationPath
        let conversion = payload.conversion
        let boxedClient = Unchecked(client)
        let token = UUID()
        lock.withLock {
            generationTasks[generationID]?.task.cancel()
            let task = Task { [weak self] in
                defer {
                    self?.lock.withLock {
                        if self?.generationTasks[generationID]?.token == token { self?.generationTasks[generationID] = nil }
                    }
                }
                do {
                    guard conversion == "#url#", let url = URL(string: original) else {
                        throw TelegramError.backend("Unsupported bot audio source.")
                    }
                    try await BotAudioFileDownload.download(from: url, to: URL(fileURLWithPath: destination))
                    try Task.checkCancellation()
                    _ = try await boxedClient.value.finishFileGeneration(error: nil, generationId: TdInt64(rawValue: generationID))
                } catch {
                    guard !Task.isCancelled else { return }
                    _ = try? await boxedClient.value.finishFileGeneration(
                        error: TDLibKit.Error(code: 400, message: error.localizedDescription),
                        generationId: TdInt64(rawValue: generationID))
                }
            }
            generationTasks[generationID] = (token, task)
        }
    }

    /// Report download progress for a tracked audio file. TDLib emits `updateFile` for every
    /// file it touches, so we only forward ones we mapped to a track in `trackFileIds`.
    private func handleFileUpdate(_ file: File) {
        let uniqueId: String? = lock.withLock { trackFileIds[file.id] }
        guard let uniqueId else { return }
        let complete = file.local.isDownloadingCompleted
        let active = file.local.isDownloadingActive
        if !active && !complete {
            // File is neither actively downloading nor completed (e.g. deleted via deleteFile or halted).
            // Stop tracking it and do not emit download progress.
            lock.withLock { trackFileIds[file.id] = nil }
            return
        }
        let total = file.size > 0 ? file.size : file.expectedSize
        let fraction = complete ? 1.0
            : (total > 0 ? min(max(Double(file.local.downloadedSize) / Double(total), 0), 1) : 0)
        // TDLib emits `updateFile` per downloaded chunk — easily tens per second per file. Each
        // one crossed to the main actor and mutated observable state, re-rendering every visible
        // track list. A download ring can't show more than ~1% anyway, so drop the rest.
        // Completion always goes through: it flips the row to "downloaded".
        let shouldEmit = lock.withLock { () -> Bool in
            if complete { lastEmittedFraction[file.id] = nil; return true }
            if let last = lastEmittedFraction[file.id], abs(fraction - last) < 0.01 { return false }
            lastEmittedFraction[file.id] = fraction
            return true
        }
        guard shouldEmit else { return }
        emitProgress(TrackDownloadProgress(remoteUniqueId: uniqueId, fraction: fraction,
                                           isComplete: complete,
                                           bytes: complete ? max(total, file.local.downloadedSize) : 0))
        if complete { lock.withLock { trackFileIds[file.id] = nil } }
    }

    private func handleConnectionState(_ state: ConnectionState) {
        switch state {
        case .connectionStateWaitingForNetwork: transitionConn(.waitingForNetwork)
        case .connectionStateConnectingToProxy, .connectionStateConnecting: transitionConn(.connecting)
        case .connectionStateUpdating: transitionConn(.updating)
        case .connectionStateReady: transitionConn(.ready)
        }
    }

    private func handleAuthState(_ state: AuthorizationState) {
        switch state {
        case .authorizationStateWaitTdlibParameters:
            Task { await sendTdlibParameters() }
        case .authorizationStateWaitPhoneNumber:
            transition(.waitingForPhoneNumber)
        case .authorizationStateWaitCode(let payload):
            let info = mapCodeInfo(payload.codeInfo)
            transition(.waitingForCode(codeInfo: info))
        case .authorizationStateWaitPassword(let payload):
            let hint = payload.passwordHint.trimmingCharacters(in: .whitespacesAndNewlines)
            transition(.waitingForPassword(hint: hint.isEmpty ? nil : hint))
        case .authorizationStateReady:
            transition(.ready)
        case .authorizationStateLoggingOut:
            // The next account will have a different id; a stale one would mislabel its
            // Saved Messages chat.
            lock.withLock { cachedSelfId = nil }
            transition(.loggingOut)
        case .authorizationStateClosed:
            transition(.closed)
            // TDLib is dead after a closed state. Recreate the client so the user can log in again.
            let shouldNukeDB = lock.withLock { () -> Bool in
                let reset = pendingAuthReset
                pendingAuthReset = false
                return reset
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if shouldNukeDB {
                    // Delete the TDLib database so the new client starts completely fresh
                    // (no stuck waitCode / waitPassword from a previous half-finished login).
                    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    try? FileManager.default.removeItem(at: support.appendingPathComponent("tdlib", isDirectory: true))
                }
                self.dropStreamers()   // they hold the client that just died
                self.setClient(self.manager.createClient { [weak self] data, client in
                    self?.handle(data: data, client: client)
                })
                await self.start()
            }
        default:
            break
        }
    }

    private func sendTdlibParameters() async {
        guard AppConfig.hasValidCredentials else {
            transition(.closed)
            return
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("tdlib", isDirectory: true)
        let dbDir = base.appendingPathComponent("database").path
        let filesDir = base.appendingPathComponent("files").path

        do {
            _ = try await client.setTdlibParameters(
                apiHash: AppConfig.telegramApiHash,
                apiId: AppConfig.telegramApiId,
                applicationVersion: "1.0.0",
                databaseDirectory: dbDir,
                databaseEncryptionKey: Data(),
                deviceModel: "iPhone",
                filesDirectory: filesDir,
                systemLanguageCode: "en-US",
                systemVersion: "iOS",
                useChatInfoDatabase: true,
                useFileDatabase: true,
                useMessageDatabase: true,
                useSecretChats: false,
                useTestDc: false
            )
        } catch {
            transition(.closed)
        }
    }

    // MARK: - TelegramBackend

    func start() async {
        // Triggering any request makes TDLib emit its initial authorization state.
        _ = try? await client.getOption(name: "version")
    }

    func setPhoneNumber(_ phone: String) async throws {
        try await mapped { _ = try await self.client.setAuthenticationPhoneNumber(phoneNumber: phone, settings: nil) }
    }

    func checkCode(_ code: String) async throws {
        try await mapped { _ = try await self.client.checkAuthenticationCode(code: code) }
    }

    func checkPassword(_ password: String) async throws {
        try await mapped { _ = try await self.client.checkAuthenticationPassword(password: password) }
    }

    /// Runs a TDLib call and converts raw `TDLibKit.Error` (code + message) into a
    /// human-readable `TelegramError` so the UI shows something meaningful.
    private func mapped<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() }
        catch let error as TDLibKit.Error { throw Self.classify(error) }
    }

    /// Split TDLib failures into "the user has to do something differently" (`.backend`, shown at
    /// once) and "the link hiccuped" (`.transient`, retried silently by `Retry`). Getting this
    /// wrong in either direction is bad: retrying a wrong code wastes the user's time, and
    /// surfacing a dropped connection makes a working app look broken.
    static func classify(_ error: TDLibKit.Error) -> TelegramError {
        let text = friendly(error)
        return isRetryable(error) ? .transient(text) : .backend(text)
    }

    static func isRetryable(_ error: TDLibKit.Error) -> Bool {
        let message = error.message.uppercased()
        // Flood waits are retryable in principle but the server told us exactly how long to sit
        // out — burning our attempts on a fixed backoff would only make it worse.
        if message.hasPrefix("FLOOD_WAIT") { return false }
        // 4xx is "your request was wrong": a bad number, a bad code, a revoked session.
        if (400..<500).contains(error.code) { return false }
        if error.code >= 500 { return true }
        // Code 0 / unset is TDLib's own client-side plumbing — almost always the link.
        return ["TIMEOUT", "TIMED OUT", "CONNECT", "NETWORK", "ABORT", "CLOSED", "UNAVAILABLE"]
            .contains { message.contains($0) }
    }

    private static func friendly(_ error: TDLibKit.Error) -> String {
        switch error.message {
        case "PHONE_NUMBER_INVALID": return "That phone number isn't valid. Check the country code and number."
        case "PHONE_NUMBER_BANNED": return "This phone number is banned from Telegram."
        case "PHONE_CODE_INVALID", "PHONE_CODE_EMPTY": return "Wrong code. Please try again."
        case "PHONE_CODE_EXPIRED": return "That code expired. Request a new one."
        case "PASSWORD_HASH_INVALID", "PASSWORD_INVALID": return "Incorrect password."
        case "PHONE_NUMBER_FLOOD": return "Too many attempts from this number. Try again later."
        default:
            if error.message.hasPrefix("FLOOD_WAIT") {
                let seconds = error.message.split(separator: "_").last.flatMap { Int($0) } ?? 0
                return "Too many attempts. Please wait \(seconds)s and try again."
            }
            return error.message.isEmpty ? "Telegram error (\(error.code))." : "\(error.message) (\(error.code))"
        }
    }

    /// Escape a stuck auth flow by flagging a database wipe, then closing the client.
    /// The `handleAuthState(.closed)` handler will delete the DB and recreate a fresh client.
    func resetAuth() async {
        lock.withLock { pendingAuthReset = true }
        _ = try? await client.close()
    }

    func logOut() async throws {
        lock.withLock { pendingAuthReset = true }
        _ = try await client.logOut()
    }

    private func mapCodeInfo(_ info: AuthenticationCodeInfo) -> TelegramCodeInfo {
        var length = 5
        var typeDesc = "Telegram app"
        var isTelegram = true
        
        switch info.type {
        case .authenticationCodeTypeTelegramMessage(let m):
            length = m.length
            typeDesc = "Telegram app on your other device"
            isTelegram = true
        case .authenticationCodeTypeSms(let s):
            length = s.length
            typeDesc = "SMS to \(info.phoneNumber)"
            isTelegram = false
        case .authenticationCodeTypeSmsWord:
            length = 5
            typeDesc = "SMS"
            isTelegram = false
        case .authenticationCodeTypeSmsPhrase:
            length = 5
            typeDesc = "SMS"
            isTelegram = false
        case .authenticationCodeTypeCall(let c):
            length = c.length
            typeDesc = "phone call"
            isTelegram = false
        case .authenticationCodeTypeFlashCall:
            length = 5
            typeDesc = "flash call"
            isTelegram = false
        case .authenticationCodeTypeMissedCall(let mc):
            length = mc.length
            typeDesc = "missed call"
            isTelegram = false
        case .authenticationCodeTypeFragment(let f):
            length = f.length
            typeDesc = "Fragment"
            isTelegram = false
        case .authenticationCodeTypeFirebaseIos(let fi):
            length = fi.length
            typeDesc = "SMS"
            isTelegram = false
        case .authenticationCodeTypeFirebaseAndroid(let fa):
            length = fa.length
            typeDesc = "SMS"
            isTelegram = false
        }
        
        return TelegramCodeInfo(
            length: length > 0 ? length : 5,
            timeout: info.timeout > 0 ? info.timeout : 60,
            typeDescription: typeDesc,
            isTelegramApp: isTelegram
        )
    }

    func loadChats(limit: Int) async throws -> [TelegramChat] {
        // Fast local query first — returns cached SQLite chats in milliseconds
        var chatsMain = (try? await client.getChats(chatList: .chatListMain, limit: limit)) ?? Chats(chatIds: [], totalCount: 0)
        
        if chatsMain.chatIds.isEmpty {
            _ = try? await client.loadChats(chatList: .chatListMain, limit: limit)
            chatsMain = (try? await client.getChats(chatList: .chatListMain, limit: limit)) ?? chatsMain
        } else {
            // Keep chat list fresh in background
            Task { [weak self] in
                _ = try? await self?.client.loadChats(chatList: .chatListMain, limit: limit)
            }
        }
        
        var seen = Set<Int64>()
        let combinedIds = chatsMain.chatIds.filter { seen.insert($0).inserted }
        
        // Resolve chats with bounded concurrency to speed up initial launch and login
        let concurrencyCap = 16
        var result: [TelegramChat] = []
        var index = 0
        
        while index < combinedIds.count {
            let slice = Array(combinedIds[index..<min(index + concurrencyCap, combinedIds.count)])
            let batchResults = await withTaskGroup(of: (Int, TelegramChat?).self) { group in
                for (batchIdx, id) in slice.enumerated() {
                    group.addTask { [weak self] in
                        guard let self, let chat = try? await self.client.getChat(chatId: id) else { return (batchIdx, nil) }
                        let mapped = await self.map(chat: chat)
                        return (batchIdx, mapped)
                    }
                }
                var batch: [(Int, TelegramChat)] = []
                for await (batchIdx, chat) in group {
                    if let chat { batch.append((batchIdx, chat)) }
                }
                return batch.sorted { $0.0 < $1.0 }.map(\.1)
            }
            result.append(contentsOf: batchResults)
            index += concurrencyCap
        }
        return result
    }

    func audioMessages(in chatId: Int64, limit: Int, fromMessageId: Int64) async throws -> [AudioTrack] {
        let found = try await client.searchChatMessages(
            chatId: chatId,
            filter: .searchMessagesFilterAudio,
            fromMessageId: fromMessageId,
            limit: limit,
            offset: 0,
            query: "",
            senderId: nil,
            topicId: nil
        )
        return found.messages.compactMap { map(message: $0, chatId: chatId) }
    }

    func chatHistory(in chatId: Int64, limit: Int, fromMessageId: Int64) async throws -> [ChatMessage] {
        let found = try await client.getChatHistory(
            chatId: chatId,
            fromMessageId: fromMessageId,
            limit: limit,
            offset: 0,
            onlyLocal: false
        )
        return found.messages?.compactMap { mapChatMessage(message: $0, chatId: chatId) } ?? []
    }

    func sendTextMessage(to chatId: Int64, text: String) async throws {
        let content = InputMessageContent.inputMessageText(
            InputMessageText(
                clearDraft: false,
                linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: text)
            )
        )
        let _ = try await client.sendMessage(
            chatId: chatId,
            inputMessageContent: content,
            options: nil,
            replyMarkup: nil,
            replyTo: nil,
            topicId: nil
        )
    }

    func sendAudioMessage(to chatId: Int64, track: AudioTrack, caption: String?) async throws {
        // Implement when media uploading is required. Currently stubs out to prevent compile errors.
    }

    func sendBotCallbackQuery(chatId: Int64, messageId: Int64, payload: Data) async throws {
        _ = try await mapped {
            try await self.client.getCallbackQueryAnswer(
                chatId: chatId,
                messageId: messageId,
                payload: .callbackQueryPayloadData(CallbackQueryPayloadData(data: payload))
            )
        }
    }

    func resolveBot(username: String) async throws -> Int64 {
        let chat = try await mapped {
            try await self.client.searchPublicChat(username: username)
        }
        guard case let .chatTypePrivate(chatPrivate) = chat.type else {
            throw TelegramError.backend("This username does not belong to an inline bot.")
        }
        let user = try await mapped { try await self.client.getUser(userId: chatPrivate.userId) }
        guard case .userTypeBot(let bot) = user.type, bot.isInline else {
            throw TelegramError.backend("This bot does not support inline search.")
        }
        return chatPrivate.userId
    }

    func channelMembership(username: String) async -> ChannelMembership {
        // Deliberately non-throwing: every failure here (offline, flood wait, a renamed
        // channel) means "we don't know", and telling the caller `.notMember` would show the
        // join prompt to someone who is already a member.
        guard let chat = try? await client.searchPublicChat(username: username) else {
            log.error("Community membership: searchPublicChat(\(username, privacy: .public)) failed")
            return .unknown
        }

        // Channels and supergroups answer through `getSupergroup`, whose `status` *is* our own
        // membership and is readable by anyone. `getChatMember` is the wrong question to ask a
        // channel you haven't joined — TDLib wants admin rights to enumerate a channel's members
        // and errors out, which read back as `.unknown` and silently suppressed the invitation
        // for exactly the people it's meant for.
        if case let .chatTypeSupergroup(info) = chat.type {
            guard let group = try? await client.getSupergroup(supergroupId: info.supergroupId) else {
                log.error("Community membership: getSupergroup failed for \(username, privacy: .public)")
                return .unknown
            }
            return Self.membership(for: group.status)
        }

        // Basic groups (and anything else) still need the per-member lookup.
        guard let me = await selfUserId(),
              let member = try? await client.getChatMember(
                  chatId: chat.id,
                  memberId: .messageSenderUser(MessageSenderUser(userId: me))
              )
        else {
            log.error("Community membership: getChatMember failed for \(username, privacy: .public)")
            return .unknown
        }
        return Self.membership(for: member.status)
    }

    private static func membership(for status: ChatMemberStatus) -> ChannelMembership {
        switch status {
        case .chatMemberStatusCreator, .chatMemberStatusAdministrator, .chatMemberStatusMember:
            return .member
        case let .chatMemberStatusRestricted(restricted):
            // Restricted covers both "member, but muted" and "not a member" — the flag decides.
            return restricted.isMember ? .member : .notMember
        case .chatMemberStatusLeft, .chatMemberStatusBanned:
            return .notMember
        }
    }

    func joinChannel(username: String) async throws {
        let chat = try await mapped {
            try await self.client.searchPublicChat(username: username)
        }
        _ = try await mapped {
            try await self.client.joinChat(chatId: chat.id)
        }
    }

    func inlineMusicSearchChatId() async throws -> Int64 {
        try await mapped {
            let me = try await self.client.getMe()
            let chat = try await self.client.createPrivateChat(force: false, userId: me.id)
            return chat.id
        }
    }

    func getInlineQueryResults(botUserId: Int64, chatId: Int64, query: String, offset: String) async throws -> AppInlineQueryResults {
        let results = try await mapped {
            try await self.client.getInlineQueryResults(
                botUserId: botUserId,
                chatId: chatId,
                offset: offset,
                query: query,
                userLocation: nil
            )
        }
        
        let mappedResults: [AppInlineQueryResult] = results.results.compactMap { res in
            switch res {
            case .inlineQueryResultArticle(let article):
                return AppInlineQueryResult(id: article.id, title: article.title, description: article.description, type: "article")
            case .inlineQueryResultPhoto(let photo):
                return AppInlineQueryResult(id: photo.id, title: photo.title, description: photo.description, type: "photo")
            case .inlineQueryResultAudio(let audio):
                return AppInlineQueryResult(id: audio.id, title: audio.audio.title, description: audio.audio.performer,
                                            type: "audio", track: Self.mapInlineAudio(audio.audio))
            case .inlineQueryResultVideo(let video):
                return AppInlineQueryResult(id: video.id, title: video.title, description: video.description, type: "video")
            case .inlineQueryResultVoiceNote(let voice):
                return AppInlineQueryResult(id: voice.id, title: voice.title, description: nil, type: "voice")
            case .inlineQueryResultAnimation(let anim):
                return AppInlineQueryResult(id: anim.id, title: anim.title, description: nil, type: "animation")
            case .inlineQueryResultDocument(let doc):
                return AppInlineQueryResult(id: doc.id, title: doc.title, description: doc.description,
                                            type: "document", track: Self.mapInlineDocument(doc.document, title: doc.title))
            default:
                return nil
            }
        }
        
        return AppInlineQueryResults(inlineQueryId: results.inlineQueryId.rawValue, botUserId: botUserId, results: mappedResults, nextOffset: results.nextOffset)
    }

    func sendInlineQueryResultMessage(chatId: Int64, botUserId: Int64, queryId: Int64, resultId: String) async throws {
        _ = try await mapped {
            try await self.client.sendInlineQueryResultMessage(
                chatId: chatId,
                hideViaBot: false,
                options: nil,
                queryId: TdInt64(rawValue: queryId),
                replyTo: nil,
                resultId: resultId,
                topicId: nil
            )
        }
    }

    func messageUpdates(for chatId: Int64) -> AsyncStream<MessageUpdate> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { messageContinuations[chatId, default: [:]][id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.messageContinuations[chatId]?.removeValue(forKey: id) }
            }
        }
    }

    func deletionUpdates() -> AsyncStream<(chatId: Int64, messageIds: [Int64])> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { deletionContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.deletionContinuations.removeValue(forKey: id) }
            }
        }
    }

    func audioCountAndLastDate(in chatId: Int64) async -> (Int, Foundation.Date?) {
        let found = try? await client.searchChatMessages(
            chatId: chatId,
            filter: .searchMessagesFilterAudio,
            fromMessageId: 0,
            limit: 1,
            offset: 0,
            query: "",
            senderId: nil,
            topicId: nil
        )
        let count = found?.totalCount ?? 0
        var date: Foundation.Date? = nil
        if let msg = found?.messages.first {
            date = Foundation.Date(timeIntervalSince1970: TimeInterval(msg.date))
        }
        return (max(count, 0), date)
    }

    func embeddedArtwork(for track: AudioTrack) async -> Data? {
        // The genuinely full-resolution cover is embedded in the audio file itself — TDLib
        // only exposes a small sender-made `albumCoverThumbnail` (its own docs say the full
        // size "is expected to be extracted from the downloaded audio file"). So if the file
        // is already on disk, pull the embedded artwork at full res. Resolve the file id the
        // *offline* way (via the stable remoteFileId, like playback does) rather than through
        // `getMessage` — that makes the embedded cover work for downloaded tracks even when
        // offline or when the original message is no longer fetchable (playlist/downloaded).
        guard let fileId = try? await resolveFileId(for: track),
              let file = try? await client.getFile(fileId: fileId),
              file.local.isDownloadingCompleted, !file.local.path.isEmpty else { return nil }
        return await Self.embeddedArtwork(atPath: file.local.path)
    }

    func thumbnailArtwork(for track: AudioTrack) async -> Data? {
        // The best available without fetching the whole file is the largest thumbnail /
        // external cover from the message. `externalAlbumCovers` are only present when the
        // file has no embedded cover; they can be larger than the thumbnail.
        guard let message = try? await client.getMessage(chatId: track.chatId, messageId: track.messageId),
              case .messageAudio(let payload) = message.content else { return nil }
        let audio = payload.audio
        let candidates = audio.externalAlbumCovers + [audio.albumCoverThumbnail].compactMap { $0 }
        if let thumbnail = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            if let file = try? await client.downloadFile(
                fileId: thumbnail.file.id, limit: 0, offset: 0, priority: 16, synchronous: true
            ), file.local.isDownloadingCompleted, !file.local.path.isEmpty,
               let data = try? Data(contentsOf: URL(fileURLWithPath: file.local.path)) {
                return data
            }
        }
        return audio.albumCoverMinithumbnail?.data
    }

    func embeddedLyrics(for track: AudioTrack) async -> String? {
        // Same offline file resolution as `embeddedArtwork` — works for downloaded/playlist
        // tracks even when offline or when the original message is gone.
        guard let fileId = try? await resolveFileId(for: track),
              let file = try? await client.getFile(fileId: fileId),
              file.local.isDownloadingCompleted, !file.local.path.isEmpty else { return nil }
        return await Self.embeddedLyrics(atPath: file.local.path)
    }

    /// Lyrics embedded in a downloaded audio file (ID3 `USLT`, iTunes/QuickTime lyrics atom),
    /// read via AVFoundation. May be plain text or LRC. Nil if the file carries none.
    private static func embeddedLyrics(atPath path: String) async -> String? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        let identifiers: [AVMetadataIdentifier] = [
            .id3MetadataUnsynchronizedLyric,   // MP3 (USLT)
            .iTunesMetadataLyrics,             // M4A / MP4
        ]
        for id in identifiers {
            for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: id) {
                if let s = try? await item.load(.stringValue),
                   !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return s
                }
            }
        }
        return nil
    }

    /// Full-resolution album art embedded in a downloaded audio file (ID3/container artwork),
    /// read via AVFoundation. Nil if the file carries no embedded cover.
    private static func embeddedArtwork(atPath path: String) async -> Data? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), !data.isEmpty { return data }
        }
        return nil
    }

    // MARK: - Streaming playback

    /// Recent streamers, kept alive because `AVURLAsset` holds its resource-loader delegate
    /// weakly. Lock-guarded like every other mutable field here: `makePlayerItem` is nonisolated
    /// `async`, so it runs off the main actor from arbitrary tasks and two concurrent loads
    /// (a track change racing a recovery reload) mutated this array unsynchronised.
    private var streamers: [TDLibFileStreamer] = []

    private func retain(_ streamer: TDLibFileStreamer) {
        lock.withLock {
            streamers.append(streamer)
            if streamers.count > 4 { streamers.removeFirst(streamers.count - 4) }
        }
    }

    /// Drop every streamer bound to a client that no longer exists. A streamer captures the client
    /// it was built with, so after TDLib closes and we recreate one (log out, auth reset, an
    /// internal `.closed`) the old streamers serve from a dead client: no error, no bytes, just a
    /// stalled player until the engine's watchdog gives up. Better to release them.
    private func dropStreamers() {
        lock.withLock {
            streamers.removeAll()
            for entry in generationTasks.values { entry.task.cancel() }
            generationTasks.removeAll()
        }
    }

    func makePlayerItem(for track: AudioTrack) async throws -> AVPlayerItem {
        let fileId = try await resolveFileId(for: track)
        trackFile(fileId, for: track.remoteUniqueId)
        // Start a non-blocking download to learn the size & current local path.
        let file = try await mapped {
            try await self.client.downloadFile(fileId: fileId, limit: 0, offset: 0, priority: 32, synchronous: false)
        }
        // Already on disk — just play it (after an authoritative sniff for unplayable containers).
        if file.local.isDownloadingCompleted, !file.local.path.isEmpty {
            try Self.verifyPlayable(AudioFormat.sniff(path: file.local.path))
            return AVPlayerItem(url: Self.playableURL(forLocalPath: file.local.path, track: track))
        }
        let size = file.size > 0 ? file.size : file.expectedSize
        // Streaming off, or unknown size: fall back to a full download.
        guard AppConfig.useStreaming, size > 0 else {
            return AVPlayerItem(url: try await ensureLocalFile(for: track))
        }

        let ext = Self.playbackExtension(for: track)
        // No local bytes to sniff yet — guess the container from the extension so an obviously
        // unplayable Opus/Ogg stream fails clearly rather than after buffering into silence.
        try Self.verifyPlayable(AudioFormat(fileExtension: ext))
        let streamer = TDLibFileStreamer(client: client, fileId: fileId, size: size, fileExtension: ext)
        retain(streamer)

        let url = URL(string: "tgstream://stream/\(track.remoteUniqueId).\(ext)")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(streamer, queue: streamer.queue)
        return AVPlayerItem(asset: asset)
    }

    func searchAudio(query: String, limit: Int) async throws -> [AudioTrack] {
        try await mapped {
            let found = try await self.client.searchMessages(
                chatList: .chatListMain,
                chatTypeFilter: nil,
                filter: .searchMessagesFilterAudio,
                limit: limit,
                maxDate: 0,
                minDate: 0,
                offset: "",
                query: query
            )
            return found.messages.compactMap { self.map(message: $0, chatId: $0.chatId) }
        }
    }

    func searchAudioPage(query: String, offset: String) async throws -> MusicSearchPage {
        try await mapped {
            let found = try await self.client.searchMessages(
                chatList: .chatListMain, chatTypeFilter: nil, filter: .searchMessagesFilterAudio,
                limit: 100, maxDate: 0, minDate: 0, offset: offset, query: query)
            return MusicSearchPage(tracks: found.messages.compactMap { self.map(message: $0, chatId: $0.chatId) },
                                   nextOffset: found.nextOffset)
        }
    }

    func profileAudioPage(offset: Int) async throws -> MusicSearchPage {
        try await mapped {
            let me = try await self.client.getMe()
            return try await self.userProfileAudioPage(userId: me.id, offset: offset)
        }
    }

    func userProfileAudioPage(userId: Int64, offset: Int) async throws -> MusicSearchPage {
        try await mapped {
            let result = try await self.client.getUserProfileAudios(limit: 100, offset: offset, userId: userId)
            let next = offset + result.audios.count
            return MusicSearchPage(tracks: result.audios.map(Self.map(profileAudio:)),
                                   nextOffset: !result.audios.isEmpty && next < result.totalCount ? String(next) : "")
        }
    }

    // MARK: - Profile audio

    func profileAudio(limit: Int) async throws -> [AudioTrack] {
        try await mapped {
            let me = try await self.client.getMe()
            return try await self.userProfileAudio(userId: me.id, limit: limit)
        }
    }

    func userProfileAudio(userId: Int64, limit: Int) async throws -> [AudioTrack] {
        try await mapped {
            let result = try await self.client.getUserProfileAudios(limit: limit, offset: 0, userId: userId)
            return result.audios.map(Self.map(profileAudio:))
        }
    }

    func addProfileAudio(_ track: AudioTrack) async throws {
        var localAudioFileId: Int?
        
        if track.chatId != 0 && track.messageId != 0 {
            _ = try? await client.getChat(chatId: track.chatId)
            if let message = try? await client.getMessage(chatId: track.chatId, messageId: track.messageId),
               case .messageAudio(let payload) = message.content {
                localAudioFileId = payload.audio.audio.id
            }
        }
        
        if localAudioFileId == nil && track.fileId > 0 {
            localAudioFileId = track.fileId
        }
        
        if localAudioFileId == nil && !track.remoteFileId.isEmpty {
            if let remote = try? await client.getRemoteFile(fileType: .fileTypeAudio, remoteFileId: track.remoteFileId) {
                localAudioFileId = remote.id
            }
        }
        
        guard let validId = localAudioFileId else {
            throw TelegramError.backend("Couldn't add “\(track.displayTitle)” to your profile. Try adding it from a chat or search.")
        }
        
        let audio = InputFile.inputFileId(.init(id: validId))
        _ = try await mapped {
            try await self.client.addProfileAudio(audio: audio, duration: track.duration,
                                                  performer: track.performer, title: track.title)
        }
    }

    func removeProfileAudio(_ track: AudioTrack) async throws {
        let fileId = try await resolveFileId(for: track)
        _ = try await mapped { try await self.client.removeProfileAudio(fileId: fileId) }
    }

    func reorderProfileAudio(_ track: AudioTrack, after afterTrack: AudioTrack?) async throws {
        let fileId = try await resolveFileId(for: track)
        var afterFileId = 0   // 0 = move to the beginning of the list
        if let afterTrack { afterFileId = try await resolveFileId(for: afterTrack) }
        _ = try await mapped {
            try await self.client.setProfileAudioPosition(afterFileId: afterFileId, fileId: fileId)
        }
    }

    /// Map a bare profile `Audio` (no enclosing message) to an `AudioTrack`. There's no chat/
    /// message behind it, so those ids are 0 and playback re-resolves the file offline via
    /// `remoteFileId` (`resolveFileId`), exactly like a rehydrated playlist track.
    private static func map(profileAudio audio: Audio) -> AudioTrack {
        AudioTrack(
            chatId: 0,
            messageId: 0,
            fileId: audio.audio.id,
            remoteUniqueId: audio.audio.remote.uniqueId,
            remoteFileId: audio.audio.remote.id,
            title: audio.title,
            performer: audio.performer,
            duration: audio.duration,
            fileName: audio.fileName,
            mimeType: audio.mimeType,
            artworkData: audio.albumCoverMinithumbnail?.data
        )
    }

    /// `getMe().id`, fetched once per session. See `cachedSelfId`.
    private func selfUserId() async -> Int64? {
        if let cached = lock.withLock({ cachedSelfId }) { return cached }
        guard let me = try? await client.getMe() else { return nil }
        lock.withLock { cachedSelfId = me.id }
        return me.id
    }

    func currentAccount() async -> TelegramAccount? {
        guard let me = try? await client.getMe() else { return nil }
        lock.withLock { cachedSelfId = me.id }
        let name = [me.firstName, me.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        let phone = me.phoneNumber.isEmpty ? "" : "+" + me.phoneNumber
        let username = me.usernames?.activeUsernames.first
        var photo: Data?
        if let big = me.profilePhoto?.big ?? me.profilePhoto?.small,
           let file = try? await client.downloadFile(fileId: big.id, limit: 0, offset: 0,
                                                      priority: 16, synchronous: true),
           file.local.isDownloadingCompleted, !file.local.path.isEmpty {
            photo = try? Data(contentsOf: URL(fileURLWithPath: file.local.path))
        }
        return TelegramAccount(name: name.isEmpty ? "Telegram" : name,
                               phone: phone, username: username, photo: photo)
    }

    func chatPhoto(chatId: Int64) async -> Data? {
        guard let chat = try? await client.getChat(chatId: chatId),
              let photo = chat.photo?.small else { return nil }
        
        let localPath = photo.local.path
        if !localPath.isEmpty && FileManager.default.fileExists(atPath: localPath) {
            return try? Data(contentsOf: URL(fileURLWithPath: localPath))
        }
        
        _ = try? await client.downloadFile(fileId: photo.id, limit: 0, offset: 0, priority: 1, synchronous: true)
        if let newPhoto = try? await client.getFile(fileId: photo.id) {
            let newLocal = newPhoto.local.path
            if !newLocal.isEmpty && FileManager.default.fileExists(atPath: newLocal) {
                return try? Data(contentsOf: URL(fileURLWithPath: newLocal))
            }
        }
        return nil
    }
    
    func canSendMessages(in chatId: Int64) async -> Bool {
        guard let chat = try? await client.getChat(chatId: chatId) else { return false }
        return chat.permissions.canSendBasicMessages
    }

    /// How long a download may make zero progress before we give up on this attempt and free the
    /// slot. Generous enough to survive a lift or a tunnel; short enough that a dead link can't
    /// pin a download slot for the rest of the session.
    private static let downloadStallTimeout: TimeInterval = 45

    func ensureLocalFile(for track: AudioTrack) async throws -> URL {
        // Tracks coming from a persisted playlist carry no session-scoped fileId (-1);
        // re-resolve it from the original message before downloading.
        let fileId = try await resolveFileId(for: track)
        trackFile(fileId, for: track.remoteUniqueId)
        var file = try await client.downloadFile(
            fileId: fileId,
            limit: 0,
            offset: 0,
            priority: 32,
            synchronous: false
        )
        if file.local.isDownloadingCompleted, !file.local.path.isEmpty {
            try Self.verifyPlayable(AudioFormat.sniff(path: file.local.path))
            return Self.playableURL(forLocalPath: file.local.path, track: track)
        }

        // Stall detection. Without it this loop polls forever when TDLib makes no progress (the
        // network went away, the DC is unreachable): the task never finishes, so it holds one of
        // the three download slots indefinitely — which is how an unrelated stuck download ends up
        // starving the track the user is actually listening to.
        var lastProgress = file.local.downloadedSize
        var lastProgressAt = Date()
        let startedAt = Date()
        var lastNudge = Date()
        while !file.local.isDownloadingCompleted {
            try Task.checkCancellation()
            if file.local.canBeDownloaded == false && !file.local.isDownloadingActive {
                throw TelegramError.backend("Download failed for \(track.displayTitle).")
            }
            if file.local.downloadedSize > lastProgress {
                lastProgress = file.local.downloadedSize
                lastProgressAt = Date()
            } else if Date().timeIntervalSince(lastProgressAt) > Self.downloadStallTimeout {
                // Transient: the caller's retry layer will start over once the link is back.
                throw TelegramError.transient("Download stalled for \(track.displayTitle).")
            }
            // Poll fast only at the start, where a cached/short file completes almost at once;
            // after that a second is plenty. At 250ms forever, three concurrent downloads plus the
            // playback lookahead was ~20 TDLib round-trips a second of pure polling — and TDLib
            // already pushes `updateFile` for the progress the UI actually reads.
            let elapsed = Date().timeIntervalSince(startedAt)
            try await Task.sleep(for: .milliseconds(elapsed < 2 ? 250 : 1000))
            // Re-assert the download only if it has genuinely gone quiet, not on a fixed tick.
            if Date().timeIntervalSince(lastProgressAt) > 10, Date().timeIntervalSince(lastNudge) > 10 {
                lastNudge = Date()
                _ = try? await client.downloadFile(fileId: fileId, limit: 0, offset: 0, priority: 32, synchronous: false)
            }
            file = try await client.getFile(fileId: fileId)
        }

        let path = file.local.path
        guard !path.isEmpty else {
            throw TelegramError.backend("Download did not complete for \(track.displayTitle).")
        }
        try Self.verifyPlayable(AudioFormat.sniff(path: path))
        return Self.playableURL(forLocalPath: path, track: track)
    }

    func cancelDownload(for track: AudioTrack) async {
        // Local-only id resolution: this runs when we are *giving up* on a track, so it must never
        // go to the network to do so.
        guard let fileId = await localFileId(for: track) else { return }
        lock.withLock {
            trackFileIds[fileId] = nil
            lastEmittedFraction[fileId] = nil
        }
        // `onlyIfPending: false` stops a transfer that is already running; the partial file stays
        // on disk, so resuming later picks up where this left off.
        _ = try? await client.cancelDownloadFile(fileId: fileId, onlyIfPending: false)
    }

    /// The TDLib file id for a track using only local lookups (never `getMessage`).
    private func localFileId(for track: AudioTrack) async -> Int? {
        if track.fileId > 0 { return track.fileId }
        guard !track.remoteFileId.isEmpty,
              let file = try? await client.getRemoteFile(fileType: .fileTypeAudio,
                                                         remoteFileId: track.remoteFileId)
        else { return nil }
        return file.id
    }

    func removeLocalFile(for track: AudioTrack) async {
        // Resolve the file id the same offline-capable way playback does, then ask TDLib to drop
        // its local copy. Best-effort: a missing/unresolvable file just means nothing to delete.
        guard let fileId = try? await resolveFileId(for: track) else { return }
        lock.withLock { trackFileIds[fileId] = nil }
        _ = try? await client.deleteFile(fileId: fileId)
    }

    func localPlayableURL(for track: AudioTrack) async -> URL? {
        // Local-only id resolution: `getRemoteFile` is a local lookup, but never fall back to
        // `getMessage` here — that needs the network and would stall offline (the whole point).
        guard let fileId = await localFileId(for: track) else { return nil }
        guard let file = try? await client.getFile(fileId: fileId),
              file.local.isDownloadingCompleted, !file.local.path.isEmpty else { return nil }
        guard (try? Self.verifyPlayable(AudioFormat.sniff(path: file.local.path))) != nil else { return nil }
        return Self.playableURL(forLocalPath: file.local.path, track: track)
    }

    func setSenderBlocked(chatId: Int64, userId: Int64?, blocked: Bool) async throws {
        try await mapped {
            // TDLib blocks *senders*, not chats: a private chat / bot blocks the user behind it,
            // while a supergroup is blocked as a chat-sender. `blockList: nil` means unblock.
            let sender: MessageSender = userId.map { .messageSenderUser(.init(userId: $0)) }
                ?? .messageSenderChat(.init(chatId: chatId))
            _ = try await self.client.setMessageSenderBlockList(
                blockList: blocked ? .blockListMain : nil,
                senderId: sender
            )
        }
    }

    func leaveChat(chatId: Int64) async throws {
        try await mapped {
            _ = try await self.client.leaveChat(chatId: chatId)
        }
    }

    func blockedSenderIds() async throws -> Set<Int64> {
        try await mapped {
            // A private chat's id *is* the user's id in TDLib, so both sender kinds map onto the
            // chat ids the app stores without a second lookup.
            var ids: Set<Int64> = []
            var offset = 0
            while true {
                let page = try await self.client.getBlockedMessageSenders(
                    blockList: .blockListMain, limit: 100, offset: offset
                )
                guard !page.senders.isEmpty else { break }
                for sender in page.senders {
                    switch sender {
                    case .messageSenderUser(let u): ids.insert(u.userId)
                    case .messageSenderChat(let c): ids.insert(c.chatId)
                    }
                }
                offset += page.senders.count
                if offset >= page.totalCount { break }
            }
            return ids
        }
    }

    func blockListUpdates() -> AsyncStream<(chatId: Int64, isBlocked: Bool)> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { blockListContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.blockListContinuations.removeValue(forKey: id) }
            }
        }
    }

    func reportChat(chatId: Int64, messageIds: [Int64]?, optionId: Data?, text: String?) async throws -> TelegramReportResult {
        try await mapped {
            let result = try await self.client.reportChat(
                chatId: chatId,
                messageIds: messageIds ?? [],
                optionId: optionId ?? Data(),
                text: text ?? ""
            )
            return Self.map(reportResult: result)
        }
    }

    private static func map(reportResult: ReportChatResult) -> TelegramReportResult {
        switch reportResult {
        case .reportChatResultOk:
            return .ok
        case .reportChatResultOptionRequired(let payload):
            let options = payload.options.map { TelegramReportOption(id: $0.id, text: $0.text) }
            return .optionRequired(title: payload.title, options: options)
        case .reportChatResultTextRequired(let payload):
            return .textRequired(optionId: payload.optionId, isOptional: payload.isOptional)
        case .reportChatResultMessagesRequired:
            // Dynamic message selection is not implemented, just return ok.
            return .ok
        }
    }

    // MARK: - File-extension handling for AVFoundation

    /// AVFoundation infers the demuxer for a **local** file from its path extension. TDLib
    /// names files after the Telegram `file_name`, which is frequently extension-less (e.g.
    /// "Hendooneh - هندونه") *or* carries a wrong one — and Telegram's `mime_type` lies too
    /// (an MP4/M4A often arrives tagged "audio/mpeg"). Either way AVFoundation fails to open it.
    ///
    /// So we sniff the file's actual magic bytes (what Telegram clients do) and expose it
    /// through a **hard link** carrying the *correct* extension. A hard link (not a symlink)
    /// matters: AVPlayer decodes out-of-process in `mediaserverd`, and the sandbox extension
    /// we hand it covers the literal path. A symlink would be *followed* to the real file in
    /// Application Support, which the extension doesn't cover → `NSCocoaError 257` "no
    /// permission". A hard link is a real directory entry for the same bytes, so it's covered
    /// directly. Reused, never copies bytes.
    static func playableURL(forLocalPath path: String, track: AudioTrack) -> URL {
        let fileURL = URL(fileURLWithPath: path)
        // Authoritative: the real container, read from the file header. Fall back to the
        // name/MIME guess only if the header is inconclusive (e.g. raw AAC has no signature).
        let ext = detectedExtension(atPath: path) ?? playbackExtension(for: track)
        // File already ends in the right extension — hand it over directly.
        if fileURL.pathExtension.lowercased() == ext { return fileURL }

        let linkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("play-\(track.remoteUniqueId)")
            .appendingPathExtension(ext)
        let fm = FileManager.default
        // Reuse the hard link if it still points at the same bytes (same inode); otherwise
        // recreate it — the underlying file can be re-downloaded to a new inode across sessions.
        func inode(_ p: String) -> UInt? {
            (try? fm.attributesOfItem(atPath: p)[.systemFileNumber] as? Int).flatMap { $0 }.map(UInt.init)
        }
        if fm.fileExists(atPath: linkURL.path), inode(linkURL.path) == inode(path) {
            return linkURL
        }
        try? fm.removeItem(at: linkURL)
        do {
            try fm.linkItem(at: fileURL, to: linkURL)
            return linkURL
        } catch {
            return fileURL   // best-effort: fall back to the raw path
        }
    }

    /// Explicitly remove all hard links we've created in the temporary directory to avoid unbounded storage bloat.
    private static func clearPlayableHardLinks() {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        guard let files = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("play-") {
            try? fm.removeItem(at: file)
        }
    }

    /// Throws a clear, user-facing error when `format` is a container AVFoundation can't decode
    /// (Opus/Ogg, Matroska/WebM). `nil`/unknown formats pass through — the on-disk paths can
    /// sniff authoritatively, the streaming path can only guess from the extension, and a wrong
    /// guess still falls through to AVPlayer's own failure (surfaced via `PlayerEngine.lastError`).
    private static func verifyPlayable(_ format: AudioFormat?) throws {
        guard let format, !format.isPlayableByAVFoundation else { return }
        throw TelegramError.unsupportedFormat(format.displayName)
    }

    /// The real audio container's extension, detected from the file's leading bytes via the
    /// shared `AudioFormat` sniffer. `nil` if the header matches no known signature (e.g.
    /// headerless ADTS AAC). Authoritative over name/MIME.
    static func detectedExtension(atPath path: String) -> String? {
        AudioFormat.sniff(path: path)?.fileExtension
    }

    /// Fallback extension when the file header is inconclusive: the file name's own, else
    /// mapped from the MIME type, else "mp3" (the overwhelming majority of Telegram music).
    static func playbackExtension(for track: AudioTrack) -> String {
        let nameExt = (track.fileName as NSString?)?.pathExtension ?? ""
        if isKnownAudioExtension(nameExt) { return nameExt.lowercased() }
        switch track.mimeType?.lowercased() {
        case "audio/mp4", "audio/x-m4a", "audio/aac", "audio/m4a": return "m4a"
        case "audio/flac", "audio/x-flac":                          return "flac"
        case "audio/wav", "audio/x-wav", "audio/wave":              return "wav"
        case "audio/ogg", "audio/opus", "audio/x-opus+ogg":         return "ogg"
        case "audio/aiff", "audio/x-aiff":                          return "aiff"
        default:                                                    return "mp3"
        }
    }

    private static func isKnownAudioExtension(_ ext: String) -> Bool {
        ["mp3", "m4a", "aac", "flac", "wav", "wave", "aiff", "aif", "caf", "ogg", "opus", "mp4"]
            .contains(ext.lowercased())
    }

    private static func isMessageDeletedError(_ error: TDLibKit.Error) -> Bool {
        let msg = error.message.uppercased()
        return msg == "MESSAGE_NOT_FOUND" ||
               msg == "MSG_NOT_FOUND" ||
               msg.contains("MESSAGE NOT FOUND") ||
               (error.code == 404 && msg.contains("MESSAGE"))
    }

    /// Use the live `fileId` when present; otherwise resolve from the persistent remote id
    /// (offline-capable), falling back to re-reading the message for legacy tracks.
    private func resolveFileId(for track: AudioTrack) async throws -> Int {
        if track.fileId > 0 { return track.fileId }
        if !track.remoteFileId.isEmpty,
           let file = try? await client.getRemoteFile(fileType: .fileTypeAudio, remoteFileId: track.remoteFileId) {
            return file.id
        }
        guard track.chatId != 0, track.messageId > 0 else {
            throw TelegramError.backend("Could not resolve audio for \(track.displayTitle).")
        }
        do {
            let message = try await client.getMessage(chatId: track.chatId, messageId: track.messageId)
            guard case .messageAudio(let payload) = message.content else {
                throw TelegramError.deleted(track.displayTitle)
            }
            return payload.audio.audio.id
        } catch let error as TDLibKit.Error {
            if Self.isMessageDeletedError(error) {
                throw TelegramError.deleted(track.displayTitle)
            }
            throw TelegramError.backend(Self.friendly(error))
        } catch {
            throw error
        }
    }

    // MARK: - Mapping

    private func map(chat: Chat) async -> TelegramChat {
        let kind: TelegramChat.Kind
        var username: String? = nil
        var userId: Int64? = nil
        var title = chat.title
        switch chat.type {
        case .chatTypeSupergroup(let s): kind = s.isChannel ? .channel : .group
        case .chatTypeBasicGroup: kind = .group
        case .chatTypePrivate(let p):
            userId = p.userId
            if let selfId = await selfUserId(), p.userId == selfId {
                kind = .savedMessages
                title = "Saved Messages"
            } else if let user = try? await client.getUser(userId: p.userId) {
                if case .userTypeBot = user.type {
                    kind = .bot
                } else {
                    kind = .privateChat
                }
                username = user.usernames?.activeUsernames.first
            } else {
                kind = .privateChat
            }
        case .chatTypeSecret: kind = .secret
        }
        return TelegramChat(id: chat.id, title: title, kind: kind,
                            userId: userId,
                            photoData: chat.photo?.minithumbnail?.data,
                            photoId: chat.photo?.small.remote.uniqueId,
                            username: username)
    }

    /// Inline audio has no source message. Its remote file reference is sufficient for the
    /// existing streaming/download pipeline and for playlist rehydration after a relaunch.
    static func mapInlineDocument(_ document: Document, title: String) -> AudioTrack? {
        let ext = (document.fileName as NSString).pathExtension.lowercased()
        guard document.mimeType.lowercased().hasPrefix("audio/") ||
              ["mp3", "m4a", "aac", "wav", "wave", "aiff", "aif", "flac", "ogg", "opus", "caf"].contains(ext) else { return nil }
        return mapInlineAudio(Audio(albumCoverMinithumbnail: document.minithumbnail, albumCoverThumbnail: document.thumbnail,
                                    audio: document.document, duration: 0, externalAlbumCovers: [],
                                    fileName: document.fileName, mimeType: document.mimeType, performer: "", title: title))
    }

    static func mapInlineAudio(_ audio: Audio) -> AudioTrack? {
        guard audio.audio.id > 0, !audio.audio.remote.id.isEmpty else { return nil }
        let remoteID = audio.audio.remote.id
        let uniqueID: String
        if !audio.audio.remote.uniqueId.isEmpty { uniqueID = audio.audio.remote.uniqueId }
        else if let url = URL(string: remoteID), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            uniqueID = "inline-url:" + SHA256.hash(data: Data(remoteID.utf8)).map { String(format: "%02x", $0) }.joined()
        } else { return nil }
        return AudioTrack(chatId: 0, messageId: 0, fileId: audio.audio.id,
                          remoteUniqueId: uniqueID, remoteFileId: remoteID,
                          title: audio.title, performer: audio.performer, duration: audio.duration,
                          fileName: audio.fileName, mimeType: audio.mimeType,
                          artworkData: audio.albumCoverMinithumbnail?.data)
    }

    private func map(message: Message, chatId: Int64) -> AudioTrack? {
        guard case .messageAudio(let payload) = message.content else { return nil }
        let audio = payload.audio
        return AudioTrack(
            chatId: chatId,
            messageId: message.id,
            fileId: audio.audio.id,
            remoteUniqueId: audio.audio.remote.uniqueId,
            remoteFileId: audio.audio.remote.id,
            title: audio.title,
            performer: audio.performer,
            duration: audio.duration,
            date: Int(message.date),
            fileName: audio.fileName,
            mimeType: audio.mimeType,
            artworkData: audio.albumCoverMinithumbnail?.data
        )
    }

    private func mapChatMessage(message: Message, chatId: Int64) -> ChatMessage? {
        var senderId: Int64 = 0
        if case .messageSenderUser(let user) = message.senderId {
            senderId = user.userId
        } else if case .messageSenderChat(let chat) = message.senderId {
            senderId = chat.chatId
        }

        let content: MessageContent
        switch message.content {
        case .messageText(let payload):
            content = .text(payload.text.text)
        case .messageAudio(_):
            if let track = map(message: message, chatId: chatId) {
                // In TDLib, messageAudio has an audio payload with a caption
                var captionText: String? = nil
                if case .messageAudio(let audioPayload) = message.content {
                    captionText = audioPayload.caption.text.isEmpty ? nil : audioPayload.caption.text
                }
                content = .audio(track: track, caption: captionText)
            } else {
                content = .unsupported
            }
        default:
            content = .unsupported
        }

        var ourMarkup: ReplyMarkup? = nil
        if case .replyMarkupInlineKeyboard(let kb) = message.replyMarkup {
            let mappedRows: [[InlineKeyboardButton]] = kb.rows.map { row in
                row.map { btn in
                    let type: InlineKeyboardButton.ButtonType
                    switch btn.type {
                    case .inlineKeyboardButtonTypeCallback(let cb):
                        type = .callback(cb.data)
                    case .inlineKeyboardButtonTypeUrl(let url):
                        type = .url(url.url)
                    case .inlineKeyboardButtonTypeSwitchInline(let sw):
                        // Assuming `inCurrentChat` is what they meant, fallback to false
                        type = .switchInline(query: sw.query, sameChat: false)
                    default:
                        type = .unsupported
                    }
                    return InlineKeyboardButton(text: btn.text, type: type)
                }
            }
            ourMarkup = ReplyMarkup(rows: mappedRows)
        }

        return ChatMessage(
            id: message.id,
            chatId: chatId,
            senderId: senderId,
            date: Date(timeIntervalSince1970: TimeInterval(message.date)),
            content: content,
            replyMarkup: ourMarkup
        )
    }
}

/// Feeds AVPlayer bytes from a TDLib file as they download, so playback can start before
/// the whole file is on disk (kills the skip/start gap). Serves arbitrary byte ranges by
/// directing TDLib to download from the requested offset and reading the downloaded prefix.
final class TDLibFileStreamer: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "grammusic.stream")
    private let client: TDLibClient
    private let fileId: Int
    private let size: Int64
    private let ext: String
    private var activeRequests: [AVAssetResourceLoadingRequest: Task<Void, Never>] = [:]
    private let lock = NSLock()

    init(client: TDLibClient, fileId: Int, size: Int64, fileExtension: String) {
        self.client = client
        self.fileId = fileId
        self.size = size
        self.ext = fileExtension
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.isByteRangeAccessSupported = true
            info.contentLength = size
            if let uti = UTType(filenameExtension: ext)?.identifier { info.contentType = uti }
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.serve(dataRequest, request: request)
        }
        lock.withLock { activeRequests[request] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.withLock { activeRequests.removeValue(forKey: loadingRequest)?.cancel() }
    }

    private func serve(_ dataRequest: AVAssetResourceLoadingDataRequest,
                       request: AVAssetResourceLoadingRequest) async {
        defer { lock.withLock { _ = activeRequests.removeValue(forKey: request) } }

        let start = dataRequest.requestedOffset
        let total = dataRequest.requestsAllDataToEndOfResource
            ? size - start
            : Int64(dataRequest.requestedLength)
        var served: Int64 = 0

        // Start TDLib downloading from 'start' to the end of file with high priority (limit: 0 means whole remainder)
        _ = try? await client.downloadFile(fileId: fileId, limit: 0, offset: start, priority: 32, synchronous: false)

        var pollCount = 0
        while served < total {
            if request.isCancelled || Task.isCancelled { return }
            let currentOffset = start + served
            let remaining = total - served
            guard remaining > 0 else { break }

            let prefix = (try? await client.getFileDownloadedPrefixSize(fileId: fileId, offset: currentOffset))?.size ?? 0
            let chunk = min(prefix, remaining)

            if chunk > 0,
               let path = (try? await client.getFile(fileId: fileId))?.local.path, !path.isEmpty,
               let data = Self.read(path: path, offset: currentOffset, length: chunk) {
                dataRequest.respond(with: data)
                served += Int64(data.count)
                pollCount = 0
            } else if let file = try? await client.getFile(fileId: fileId), file.local.isDownloadingCompleted {
                let path = file.local.path
                if !path.isEmpty, remaining > 0,
                   let data = Self.read(path: path, offset: currentOffset, length: remaining) {
                    dataRequest.respond(with: data)
                    served += Int64(data.count)
                }
                break
            } else {
                pollCount += 1
                // Re-nudge TDLib if stalled for > 3s (30 * 100ms) without new bytes
                if pollCount % 30 == 0 {
                    _ = try? await client.downloadFile(fileId: fileId, limit: 0, offset: currentOffset, priority: 32, synchronous: false)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        if !request.isCancelled && !Task.isCancelled {
            request.finishLoading()
        }
    }

    private static func read(path: String, offset: Int64, length: Int64) -> Data? {
        guard length > 0, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: Int(length))
        } catch { return nil }
    }
}

#else

/// Fallback when the TDLib package isn't resolved yet — keeps the app compiling.
/// `AppConfig.useMockTelegram` should be `true` in this state.
final class TDLibTelegramBackend: TelegramBackend, @unchecked Sendable {
    func authStates() -> AsyncStream<TelegramAuthState> {
        AsyncStream { $0.yield(.closed); $0.finish() }
    }
    func connectionStates() -> AsyncStream<TelegramConnectionState> {
        AsyncStream { $0.yield(.ready); $0.finish() }
    }
    func downloadProgress() -> AsyncStream<TrackDownloadProgress> {
        AsyncStream { $0.finish() }
    }
    func start() async {}
    func setPhoneNumber(_ phone: String) async throws { throw TelegramError.backend("TDLibKit not linked.") }
    func checkCode(_ code: String) async throws { throw TelegramError.backend("TDLibKit not linked.") }
    func checkPassword(_ password: String) async throws { throw TelegramError.backend("TDLibKit not linked.") }
    func logOut() async throws {}
    func resetAuth() async {}
    func currentAccount() async -> TelegramAccount? { nil }
    func loadChats(limit: Int) async throws -> [TelegramChat] { [] }
    func audioMessages(in chatId: Int64, limit: Int, fromMessageId: Int64) async throws -> [AudioTrack] { [] }
    func audioCountAndLastDate(in chatId: Int64) async -> (Int, Date?) { (0, nil) }
    func ensureLocalFile(for track: AudioTrack) async throws -> URL { throw TelegramError.backend("TDLibKit not linked.") }
    func removeLocalFile(for track: AudioTrack) async {}
    func cancelDownload(for track: AudioTrack) async {}
    func embeddedArtwork(for track: AudioTrack) async -> Data? { nil }
    func thumbnailArtwork(for track: AudioTrack) async -> Data? { nil }
    func embeddedLyrics(for track: AudioTrack) async -> String? { nil }
    func chatPhoto(chatId: Int64) async -> Data? { nil }
    func searchAudio(query: String, limit: Int) async throws -> [AudioTrack] { [] }
    func profileAudio(limit: Int) async throws -> [AudioTrack] { [] }
    func userProfileAudio(userId: Int64, limit: Int) async throws -> [AudioTrack] { [] }
    func addProfileAudio(_ track: AudioTrack) async throws {}
    func removeProfileAudio(_ track: AudioTrack) async throws {}
    func reorderProfileAudio(_ track: AudioTrack, after afterTrack: AudioTrack?) async throws {}
    func makePlayerItem(for track: AudioTrack) async throws -> AVPlayerItem { throw TelegramError.backend("TDLibKit not linked.") }
    func localPlayableURL(for track: AudioTrack) async -> URL? { nil }
    func setSenderBlocked(chatId: Int64, userId: Int64?, blocked: Bool) async throws {}
    func leaveChat(chatId: Int64) async throws {}
    func blockedSenderIds() async throws -> Set<Int64> { [] }
    func blockListUpdates() -> AsyncStream<(chatId: Int64, isBlocked: Bool)> { AsyncStream { $0.finish() } }
    func reportChat(chatId: Int64, messageIds: [Int64]?, optionId: Data?, text: String?) async throws -> TelegramReportResult { .ok }
    func chatHistory(in chatId: Int64, limit: Int, fromMessageId: Int64) async throws -> [ChatMessage] { [] }
    func canSendMessages(in chatId: Int64) async -> Bool { false }
    func sendTextMessage(to chatId: Int64, text: String) async throws {}
    func sendAudioMessage(to chatId: Int64, track: AudioTrack, caption: String?) async throws {}
    func sendBotCallbackQuery(chatId: Int64, messageId: Int64, payload: Data) async throws {}
    func resolveBot(username: String) async throws -> Int64 { 0 }
    func channelMembership(username: String) async -> ChannelMembership { .unknown }
    func joinChannel(username: String) async throws {}
    func getInlineQueryResults(botUserId: Int64, chatId: Int64, query: String, offset: String) async throws -> AppInlineQueryResults {
        AppInlineQueryResults(inlineQueryId: 0, botUserId: botUserId, results: [])
    }
    func sendInlineQueryResultMessage(chatId: Int64, botUserId: Int64, queryId: Int64, resultId: String) async throws {}
    func messageUpdates(for chatId: Int64) -> AsyncStream<MessageUpdate> { AsyncStream { $0.finish() } }
    func deletionUpdates() -> AsyncStream<(chatId: Int64, messageIds: [Int64])> { AsyncStream { $0.finish() } }
    func chatListUpdates() -> AsyncStream<ChatListEvent> { AsyncStream { $0.finish() } }
    func accountUpdates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

#endif

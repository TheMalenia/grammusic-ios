import Foundation
import AVFoundation

/// In-memory Telegram stand-in so the whole app builds, runs, and is demoable without
/// the TDLib package, real credentials, or a phone login. It even synthesizes short
/// playable audio files so the player, queue, and now-playing UI work end to end.
///
/// Mock login: enter any phone number, then any code. (Enter code `2fa` to exercise the
/// two-factor password screen — any password then succeeds.)
actor MockTelegramBackend: TelegramBackend {

    /// Whether a completed login survives relaunch. The **demo** account (App Review) needs it —
    /// reopening the app must not dump the reviewer back on the phone screen — while plain mock
    /// development mode keeps starting at the login flow so it stays exercisable.
    private let persistsSession: Bool
    private static let signedInKey = "n_mockSignedIn"

    /// Whether `start()` should come up already signed in. The mock used to decide this purely
    /// from its own `n_mockSignedIn` key, which is written *by the backend instance that handled
    /// the login* — so any path that reached `.ready` on a different instance (or that replaced
    /// the backend mid-login) silently lost the session and dumped the reviewer back on the phone
    /// screen at the next launch. `TelegramService` owns the durable answer and passes it in.
    private let startsSignedIn: Bool

    init(persistsSession: Bool = false, startsSignedIn: Bool = false) {
        self.persistsSession = persistsSession
        self.startsSignedIn = startsSignedIn
    }

    private var state: TelegramAuthState = .initializing
    private var continuations: [UUID: AsyncStream<TelegramAuthState>.Continuation] = [:]
    private var fileCache: [String: URL] = [:]
    private var progressContinuations: [UUID: AsyncStream<TrackDownloadProgress>.Continuation] = [:]

    nonisolated func authStates() -> AsyncStream<TelegramAuthState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(continuation, id: id) }
            continuation.onTermination = { _ in Task { await self.unregister(id) } }
        }
    }

    private func register(_ c: AsyncStream<TelegramAuthState>.Continuation, id: UUID) {
        continuations[id] = c
        c.yield(state)
    }

    private func unregister(_ id: UUID) { continuations[id] = nil }

    nonisolated func connectionStates() -> AsyncStream<TelegramConnectionState> {
        AsyncStream { $0.yield(.ready); $0.finish() }
    }

    nonisolated func downloadProgress() -> AsyncStream<TrackDownloadProgress> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerProgress(continuation, id: id) }
            continuation.onTermination = { _ in Task { await self.unregisterProgress(id) } }
        }
    }

    private func registerProgress(_ c: AsyncStream<TrackDownloadProgress>.Continuation, id: UUID) {
        progressContinuations[id] = c
    }

    private func unregisterProgress(_ id: UUID) { progressContinuations[id] = nil }

    private func emitProgress(_ update: TrackDownloadProgress) {
        for c in progressContinuations.values { c.yield(update) }
    }

    /// Simulate a brief download so the filling-circle UI is exercised in mock mode.
    private func simulateDownload(_ uniqueId: String) async {
        for step in 1...5 {
            try? await Task.sleep(for: .milliseconds(180))
            emitProgress(TrackDownloadProgress(remoteUniqueId: uniqueId,
                                               fraction: Double(step) / 5, isComplete: false))
        }
        emitProgress(TrackDownloadProgress(remoteUniqueId: uniqueId, fraction: 1, isComplete: true))
    }

    private func transition(_ new: TelegramAuthState) {
        state = new
        if persistsSession {
            switch new {
            case .ready: UserDefaults.standard.set(true, forKey: Self.signedInKey)
            case .waitingForPhoneNumber, .closed:
                UserDefaults.standard.set(false, forKey: Self.signedInKey)
            default: break
            }
        }
        for c in continuations.values { c.yield(new) }
    }

    func start() async {
        try? await Task.sleep(for: .milliseconds(300))
        if persistsSession, startsSignedIn || UserDefaults.standard.bool(forKey: Self.signedInKey) {
            transition(.ready)
        } else {
            transition(.waitingForPhoneNumber)
        }
    }

    func setPhoneNumber(_ phone: String) async throws {
        try await Task.sleep(for: .milliseconds(200))
        let codeInfo = TelegramCodeInfo(length: 5, timeout: 45,
                                        typeDescription: "Telegram app on your other device",
                                        isTelegramApp: true)
        transition(.waitingForCode(codeInfo: codeInfo))
    }

    func checkCode(_ code: String) async throws {
        try await Task.sleep(for: .milliseconds(200))
        if code.lowercased() == "2fa" {
            transition(.waitingForPassword(hint: "Favorite musician / album"))
        } else {
            transition(.ready)
        }
    }

    func checkPassword(_ password: String) async throws {
        try await Task.sleep(for: .milliseconds(300))
        transition(.ready)
    }

    func logOut() async throws {
        transition(.loggingOut)
        try await Task.sleep(for: .milliseconds(100))
        transition(.waitingForPhoneNumber)
    }

    func resetAuth() async {
        transition(.waitingForPhoneNumber)
    }

    /// Test seam: emit the transient `.closed` state TDLib produces when it tears down and
    /// recreates its client, so the "this is not a remote sign-out" rule can be covered.
    func emitClosedForTesting() {
        transition(.closed)
    }

    func currentAccount() async -> TelegramAccount? {
        TelegramAccount(name: "Demo User", phone: "+1 555 0100", username: "demo", photo: nil)
    }

    func loadChats(limit: Int) async throws -> [TelegramChat] {
        try await Task.sleep(for: .milliseconds(250))
        return Self.sampleChats
    }

    func audioMessages(in chatId: Int64, limit: Int, fromMessageId: Int64) async throws -> [AudioTrack] {
        try await Task.sleep(for: .milliseconds(250))
        return fromMessageId == 0 ? Self.sampleTracks(for: chatId) : []   // single page in mock
    }

    func audioCountAndLastDate(in chatId: Int64) async -> (Int, Date?) { (Self.sampleTracks(for: chatId).count, Date()) }

    func embeddedArtwork(for track: AudioTrack) async -> Data? { nil }
    func thumbnailArtwork(for track: AudioTrack) async -> Data? { nil }

    func embeddedLyrics(for track: AudioTrack) async -> String? {
        // A short synced sample so the karaoke highlight + auto-scroll are exercised in mock mode.
        guard !track.title.isEmpty else { return nil }
        return """
        [00:00.00] \(track.displayTitle)
        [00:02.00] by \(track.displaySubtitle)
        [00:04.50] (sample synced lyrics)
        [00:07.00] line three rolls in
        [00:10.00] and the chorus repeats
        [00:13.00] la la la
        [00:16.00] fading out…
        """
    }

    func chatPhoto(chatId: Int64) async -> Data? { nil }

    func makePlayerItem(for track: AudioTrack) async throws -> AVPlayerItem {
        AVPlayerItem(url: try await ensureLocalFile(for: track))
    }

    func searchAudio(query: String, limit: Int) async throws -> [AudioTrack] {
        try? await Task.sleep(for: .milliseconds(250))
        let all = Self.sampleChats.flatMap { Self.sampleTracks(for: $0.id) }
        // Same folding/ranking as the real path, so mock mode exercises the engine rather than a
        // second, subtly different matcher.
        return AudioSearch.rank(all, query: query, limit: limit)
    }

    // MARK: - Profile audio (in-memory mirror of "songs on your profile")

    /// Seeded so the Profile Music smart playlist is exercisable in mock mode; mutated by the
    /// add/remove/reorder methods just like the real server-backed list.
    private lazy var profileAudios: [AudioTrack] = Array(Self.sampleTracks(for: 1).prefix(3))

    func profileAudio(limit: Int) async throws -> [AudioTrack] {
        try? await Task.sleep(for: .milliseconds(150))
        return Array(profileAudios.prefix(limit))
    }

    func userProfileAudio(userId: Int64, limit: Int) async throws -> [AudioTrack] {
        try? await Task.sleep(for: .milliseconds(150))
        if userId == 106 {
            // Sample profile music tracks for Hasan
            return Array(Self.sampleTracks(for: 6).prefix(4))
        }
        if userId == 1 {
            return Array(profileAudios.prefix(limit))
        }
        return []
    }

    func addProfileAudio(_ track: AudioTrack) async throws {
        profileAudios.removeAll { $0.remoteUniqueId == track.remoteUniqueId }
        profileAudios.insert(track, at: 0)   // newest first, like the server
    }

    func removeProfileAudio(_ track: AudioTrack) async throws {
        profileAudios.removeAll { $0.remoteUniqueId == track.remoteUniqueId }
    }

    func reorderProfileAudio(_ track: AudioTrack, after afterTrack: AudioTrack?) async throws {
        guard let from = profileAudios.firstIndex(where: { $0.remoteUniqueId == track.remoteUniqueId }) else { return }
        let moved = profileAudios.remove(at: from)
        if let afterTrack, let after = profileAudios.firstIndex(where: { $0.remoteUniqueId == afterTrack.remoteUniqueId }) {
            profileAudios.insert(moved, at: after + 1)
        } else {
            profileAudios.insert(moved, at: 0)
        }
    }

    func ensureLocalFile(for track: AudioTrack) async throws -> URL {
        if let url = fileCache[track.remoteUniqueId] { return url }
        // Drive the filling-circle UI (and the auto-record-on-completion path) in mock mode.
        // Awaited so it mirrors the real backend, which only returns once fully downloaded.
        await simulateDownload(track.remoteUniqueId)
        let url = try Self.materialize(track)
        fileCache[track.remoteUniqueId] = url
        return url
    }

    /// Put a playable file on disk for a mock track.
    ///
    /// Prefers the **bundled demo clip** (minutes of real music — see `DemoAudioLibrary` for why
    /// that matters) and copies it into tmp rather than handing back the bundle URL directly, so
    /// `removeLocalFile` can delete it like any other download instead of silently failing against
    /// a read-only bundle. Falls back to a synthesized tone only when the resource is absent, which
    /// is the unit-test bundle's situation — tests exercise the shape of playback, not its sound.
    private static func materialize(_ track: AudioTrack) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory

        if let clip = clip(for: track), let source = DemoAudioLibrary.url(for: clip) {
            let url = tmp.appendingPathComponent("mock-\(track.remoteUniqueId).mp3")
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.copyItem(at: source, to: url)
            }
            return url
        }

        let seconds = min(max(track.duration, 3), 8)
        let url = tmp.appendingPathComponent("mock-\(track.remoteUniqueId).wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            let frequency = 220.0 + Double(abs(track.remoteUniqueId.hashValue) % 6) * 55.0
            let data = ToneGenerator.wav(seconds: Double(seconds), frequency: frequency)
            try data.write(to: url)
        }
        return url
    }

    /// Which bundled clip a mock track plays. `sampleTracks` stamps the index into the unique id
    /// precisely so this is a lookup and not a guess from the (user-visible, mutable) title.
    private static func clip(for track: AudioTrack) -> DemoAudioLibrary.Clip? {
        guard let raw = track.remoteUniqueId.split(separator: "-").last,
              let index = Int(raw.replacingOccurrences(of: "clip", with: "")),
              track.remoteUniqueId.contains("clip") else { return nil }
        return DemoAudioLibrary.clip(at: index)
    }

    /// Ids passed to `removeLocalFile`. Deleting a partial download throws away bytes the user
    /// may be seconds from needing again, so tests assert on *who* deletes and who merely stops
    /// chasing; this records the difference.
    private(set) var removedLocalFileIds: Set<String> = []

    /// Ids passed to `cancelDownload` — "stop fetching this, but keep what you have".
    private(set) var cancelledDownloadIds: Set<String> = []

    func cancelDownload(for track: AudioTrack) async {
        cancelledDownloadIds.insert(track.remoteUniqueId)
    }

    func removeLocalFile(for track: AudioTrack) async {
        removedLocalFileIds.insert(track.remoteUniqueId)
        if let url = fileCache.removeValue(forKey: track.remoteUniqueId) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func localPlayableURL(for track: AudioTrack) async -> URL? {
        // Only if the synthesized tone is already on disk (no "download" simulated).
        if let url = fileCache[track.remoteUniqueId], FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    /// Senders blocked through `setSenderBlocked`, and chats left through `leaveChat`. Tests
    /// assert on *which* of the two a given chat kind takes.
    private(set) var blockedSenderChatIds: Set<Int64> = []
    private(set) var leftChatIds: Set<Int64> = []

    func setSenderBlocked(chatId: Int64, userId: Int64?, blocked: Bool) async throws {
        if blocked { blockedSenderChatIds.insert(chatId) } else { blockedSenderChatIds.remove(chatId) }
    }

    func leaveChat(chatId: Int64) async throws {
        leftChatIds.insert(chatId)
    }

    /// Lets tests simulate "the user unblocked them in Telegram".
    func setBlockedSenders(_ ids: Set<Int64>) { blockedSenderChatIds = ids }

    /// Makes the block-list fetch throw, so tests can prove a failed sync leaves the local list
    /// alone rather than treating "no answer" as "nobody is blocked".
    private var blockListFetchFails = false
    func setBlockListFetchFails(_ fails: Bool) { blockListFetchFails = fails }

    func blockedSenderIds() async throws -> Set<Int64> {
        if blockListFetchFails { throw TelegramError.transient("no link") }
        return blockedSenderChatIds
    }

    nonisolated func blockListUpdates() -> AsyncStream<(chatId: Int64, isBlocked: Bool)> {
        AsyncStream { $0.finish() }
    }

    func reportChat(chatId: Int64, messageIds: [Int64]?, optionId: Data?, text: String?) async throws -> TelegramReportResult {
        try? await Task.sleep(for: .milliseconds(300))
        if optionId == nil {
            return .optionRequired(title: "Report", options: [
                TelegramReportOption(id: "spam".data(using: .utf8)!, text: "Spam"),
                TelegramReportOption(id: "violence".data(using: .utf8)!, text: "Violence"),
                TelegramReportOption(id: "other".data(using: .utf8)!, text: "Other")
            ])
        }
        if optionId == "other".data(using: .utf8)! && text == nil {
            return .textRequired(optionId: optionId!, isOptional: false)
        }
        return .ok
    }

    func chatHistory(in chatId: Int64, limit: Int, fromMessageId: Int64) async throws -> [ChatMessage] {
        return [] // Not fully mocked
    }

    func canSendMessages(in chatId: Int64) async -> Bool {
        return true
    }

    func sendTextMessage(to chatId: Int64, text: String) async throws {}

    func sendAudioMessage(to chatId: Int64, track: AudioTrack, caption: String?) async throws {}

    func sendBotCallbackQuery(chatId: Int64, messageId: Int64, payload: Data) async throws {}

    nonisolated func messageUpdates(for chatId: Int64) -> AsyncStream<MessageUpdate> {
        AsyncStream { $0.finish() }
    }

    nonisolated func deletionUpdates() -> AsyncStream<(chatId: Int64, messageIds: [Int64])> {
        AsyncStream { $0.finish() }
    }

    nonisolated func chatListUpdates() -> AsyncStream<ChatListEvent> {
        AsyncStream { $0.finish() }
    }

    nonisolated func accountUpdates() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }

    func resolveBot(username: String) async throws -> Int64 {
        let value = try MusicSearchBot.normalizedUsername(username)
        guard value.hasSuffix("bot") else { throw TelegramError.backend("This bot does not support inline search.") }
        // Deterministic across launches; Swift's hashValue is deliberately randomized.
        return value.utf8.reduce(Int64(1000)) { ($0 * 31 + Int64($1)) % 1_000_000_007 } + 1
    }

    /// Mock/demo mode starts out *not* a member so the join prompt is exercisable, and
    /// remembers the join for the rest of the session.
    private var joinedChannels: Set<String> = []

    func channelMembership(username: String) async -> ChannelMembership {
        joinedChannels.contains(username.lowercased()) ? .member : .notMember
    }

    func joinChannel(username: String) async throws {
        joinedChannels.insert(username.lowercased())
    }
    
    func getInlineQueryResults(botUserId: Int64, chatId: Int64, query: String, offset: String) async throws -> AppInlineQueryResults {
        let tracks = AudioSearch.rank(Self.sampleChats.flatMap { Self.sampleTracks(for: $0.id) }, query: query)
        let start = Int(offset) ?? 0
        let page = Array(tracks.dropFirst(start).prefix(5))
        let results = page.map { track in
            AppInlineQueryResult(id: track.remoteUniqueId, title: track.displayTitle,
                                 description: track.displaySubtitle, type: "audio", track: track)
        }
        return AppInlineQueryResults(inlineQueryId: 1, botUserId: botUserId, results: results,
                                    nextOffset: start + page.count < tracks.count ? String(start + page.count) : "")
    }
    
    func sendInlineQueryResultMessage(chatId: Int64, botUserId: Int64, queryId: Int64, resultId: String) async throws {
    }

    // MARK: - Sample data

    static let sampleChats: [TelegramChat] = [
        .init(id: 1, title: "Saved Messages", kind: .savedMessages, userId: 1),
        .init(id: 2, title: "Piano Archive", kind: .channel),
        .init(id: 3, title: "Bach Discoveries", kind: .channel),
        .init(id: 4, title: "Road Trip Crew", kind: .group),
        .init(id: 5, title: "Classical Archive", kind: .channel),
        .init(id: 6, title: "Hasan", kind: .privateChat, userId: 106),
    ]

    /// The mock library, built from the **bundled** demo clips.
    ///
    /// Titles, performers and durations are the real ones for the audio that will actually play.
    /// They used to be invented ("Midnight Drive" by "Neon Hours") over 8-second tones, so every
    /// row, the scrubber and the Lock Screen all described something that did not exist — which is
    /// a bad look in the one mode App Review sees. Each chat is rotated through the catalog so
    /// chats differ from one another.
    static func sampleTracks(for chatId: Int64) -> [AudioTrack] {
        let offset = Int(abs(chatId))
        return (0..<DemoAudioLibrary.clips.count).map { position in
            let index = (offset + position) % DemoAudioLibrary.clips.count
            let clip = DemoAudioLibrary.clip(at: index)
            // `clip<index>` is the handle `materialize` resolves back to the bundled file.
            let unique = "chat\(chatId)-clip\(index)"
            return AudioTrack(
                chatId: chatId,
                messageId: Int64(1000 + position),
                fileId: index,
                remoteUniqueId: unique,
                title: clip.title,
                performer: clip.performer,
                duration: clip.duration,
                fileName: "\(clip.title).mp3",
                artworkData: nil
            )
        }
    }
}

/// Tiny PCM-16 mono WAV generator used only by the mock backend.
enum ToneGenerator {
    static func wav(seconds: Double, frequency: Double, sampleRate: Int = 44_100) -> Data {
        let frameCount = Int(seconds * Double(sampleRate))
        var samples = Data(capacity: frameCount * 2)
        let amplitude = 0.2 * Double(Int16.max)
        for n in 0..<frameCount {
            let t = Double(n) / Double(sampleRate)
            // gentle fade in/out to avoid clicks
            let env = min(1, min(t * 4, (seconds - t) * 4))
            let value = Int16(amplitude * env * sin(2 * .pi * frequency * t))
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        return riffWrap(pcm: samples, sampleRate: sampleRate)
    }

    private static func riffWrap(pcm: Data, sampleRate: Int) -> Data {
        var data = Data()
        let byteRate = sampleRate * 2
        func append(_ string: String) { data.append(contentsOf: string.utf8) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF"); append32(UInt32(36 + pcm.count)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(byteRate)); append16(2); append16(16)
        append("data"); append32(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}

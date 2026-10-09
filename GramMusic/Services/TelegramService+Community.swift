import Foundation
import UIKit

/// The app's own Telegram channel (news + releases) — membership lookup, joining, and the
/// one-time "join us" prompt's gate.
///
/// Split out of `TelegramService.swift` for the same reason as the other extensions: the state
/// (`communityMembership`, `isJoiningCommunity`) has to be stored on the main type, but the
/// logic doesn't have to live there.
@MainActor
extension TelegramService {

    /// Whether the one-time join page has already been shown (or dismissed) on this account.
    /// Cleared with the rest of the per-account state in `wipeLocalAccountData()`.
    static let communityPromptSeenKey = "n_didSeeChannelPrompt"

    var hasSeenCommunityPrompt: Bool {
        get { UserDefaults.standard.bool(forKey: Self.communityPromptSeenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.communityPromptSeenKey) }
    }

    /// The prompt is shown **once**, and only to someone we actually know isn't a member —
    /// `.unknown` (offline, flood wait, lookup failed) deliberately doesn't qualify, because
    /// nagging an existing member is worse than never asking.
    var shouldShowCommunityPrompt: Bool {
        !hasSeenCommunityPrompt && communityMembership == .notMember
    }

    /// Forget that the prompt was shown, so the next signed-in session offers the channel again.
    /// Called when a *fresh* login completes — logging out and back in is the one moment where
    /// re-asking is right, and it's also what makes the page testable without deleting the app.
    func resetCommunityPrompt() {
        hasSeenCommunityPrompt = false
        communityMembership = .unknown
    }

    /// Refresh `communityMembership` from Telegram. Cheap and silent: no error surfaces, and
    /// it no-ops while offline (the answer would only ever be `.unknown`).
    ///
    /// `.unknown` is retried a few times rather than accepted: the first lookup after login often
    /// lands while TDLib is still finishing its own sync, and one unlucky answer would otherwise
    /// suppress the invitation for the whole session. A known answer is never downgraded back to
    /// `.unknown` by a later failure.
    func refreshCommunityMembership(attempts: Int = 3) async {
        for attempt in 0..<max(1, attempts) {
            guard !isOffline else { return }
            let result = await backend.channelMembership(
                username: AppConfig.communityChannelUsername
            )
            if result != .unknown || communityMembership == .unknown {
                communityMembership = result
            }
            if result != .unknown { return }
            if attempt < attempts - 1, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Join the channel. Returns `true` on success; on failure the membership is left alone so
    /// the caller can offer the "Open in Telegram" fallback.
    @discardableResult
    func joinCommunityChannel() async -> Bool {
        guard !isJoiningCommunity else { return false }
        isJoiningCommunity = true
        defer { isJoiningCommunity = false }
        do {
            try await backend.joinChannel(username: AppConfig.communityChannelUsername)
            communityMembership = .member
            return true
        } catch {
            log.error("Joining \(AppConfig.communityChannelUsername) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Open the channel in the Telegram app, falling back to t.me in the browser.
    func openCommunityChannel() {
        let app = UIApplication.shared
        if app.canOpenURL(AppConfig.communityChannelAppURL) {
            app.open(AppConfig.communityChannelAppURL)
        } else {
            app.open(AppConfig.communityChannelURL)
        }
    }
}

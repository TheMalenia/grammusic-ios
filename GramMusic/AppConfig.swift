import Foundation

/// App-wide configuration. Telegram credentials are read from Info.plist, which is
/// populated from Config/Secrets.xcconfig at build time.
enum AppConfig {

    /// Flip to `false` once you've added real credentials and want to talk to Telegram.
    /// While `true`, the app runs entirely on in-memory mock data so it builds and runs
    /// before the (large) TDLib package is resolved or any login happens.
    static let useMockTelegram = false

    /// Ships the AI tab. **Off — the feature isn't finished.**
    ///
    /// Distinct from `AppSettings.aiTabEnabled`, which is the *user's* preference once the
    /// feature ships. This is the release gate: while it's `false` neither the tab nor its
    /// Settings row exists, so nothing half-built is reachable.
    ///
    /// What's still missing before this can be `true`: a Composer that *selects* from the roster
    /// using knowledge of music rather than matching names the user already typed, plus genre and
    /// language signals so requests like "Iranian dance music" have anything to match on. The
    /// layer below the UI (`PlaylistComposer`, `SnapshotHydrator`, `RecipeSelector`) is finished
    /// and stays under test at 95 tests, so it doesn't rot while this is off.
    static let aiEnabled = false

    /// Stream tracks (play while downloading) instead of waiting for the full file. Now a
    /// user-facing setting (Settings ▸ Playback), persisted in UserDefaults, default on.
    /// If streaming ever misbehaves on a track, the user can turn it off.
    private static let streamingKey = "streamWhileDownloading"
    static var useStreaming: Bool {
        get { UserDefaults.standard.object(forKey: streamingKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: streamingKey) }
    }

    static var telegramApiId: Int {
        let raw = infoValue("TelegramApiId") ?? "0"
        return Int(raw) ?? 0
    }

    static var telegramApiHash: String {
        infoValue("TelegramApiHash") ?? ""
    }

    /// True when real, non-placeholder credentials are present.
    static var hasValidCredentials: Bool {
        telegramApiId != 0 && !telegramApiHash.isEmpty && telegramApiHash != "your_api_hash_here"
    }

    /// Demo phone number for Apple App Review (and manual QA).
    ///
    /// Entering it swaps the app onto `MockTelegramBackend` — canned chats, tracks and
    /// synthesized audio, entirely on-device. **No real Telegram account is involved**: nothing
    /// is sent to Telegram's servers, and no session key ships in the app. Any login code is
    /// accepted. Give this number to Apple in the App Store Connect review notes.
    ///
    /// This deliberately replaces the old "bundled reviewer session" approach, which shipped a
    /// live account's TDLib auth keys inside the IPA behind a hardcoded password.
    static let demoPhoneNumber = "+1 555 0100"

    /// Persisted so a demo session survives relaunch (the reviewer may background the app).
    /// Cleared on log out.
    static let demoModeKey = "n_demoMode"

    static var isDemoModeActive: Bool {
        get { UserDefaults.standard.bool(forKey: demoModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: demoModeKey) }
    }

    /// Normalizes and checks whether an entered phone number is the demo number.
    static func isDemoPhoneNumber(_ phone: String) -> Bool {
        let cleanInput = phone.filter(\.isNumber)
        let cleanDemo = demoPhoneNumber.filter(\.isNumber)
        guard !cleanDemo.isEmpty, !cleanInput.isEmpty else { return false }
        return cleanInput == cleanDemo
    }

    /// The app's own public Telegram channel (news + releases). Username without the `@`.
    /// Surfaced by the one-time join prompt and the Settings ▸ Community row.
    static let communityChannelUsername = "GramMusicApp"

    /// Deep link into the channel — `tg://` opens the Telegram app when it's installed;
    /// `t.me` is the web fallback.
    static var communityChannelURL: URL {
        URL(string: "https://t.me/\(communityChannelUsername)")!
    }

    static var communityChannelAppURL: URL {
        URL(string: "tg://resolve?domain=\(communityChannelUsername)")!
    }

    // MARK: - Legal

    /// The Terms of Use version the app currently ships. Bumping it re-presents the agreement to
    /// everyone — which is what App Review guideline 1.2 expects after a material change, and the
    /// reason acceptance is stored as a version rather than a bool.
    ///
    /// **Keep in step with the date at the top of `Resources/Legal/TermsOfUse.md`.**
    static let termsVersion = 1

    /// Hosted copies. The *authoritative* text a user agrees to is the one bundled in
    /// `Resources/Legal/TermsOfUse.md` and shown by `NTermsGateView` — bundled so the agreement
    /// is readable with no network and can never 404 during review. These links are the
    /// out-of-app copies (App Store Connect also requires the privacy URL).
    static let privacyPolicyURL = URL(string: "https://doc-hosting.flycricket.io/grammusic/a023e4cd-f52b-438e-8dbf-053f431f2c92/privacy")!

    /// The hosted Terms of Use. Keep its text in step with `Resources/Legal/TermsOfUse.md`, which
    /// is what the in-app viewer shows — the bundled copy is the one that is guaranteed to open
    /// during review, with no network and no chance of a 404.
    static let termsOfUseURL = URL(string: "https://doc-hosting.flycricket.io/grammusic-terms/6536b7d3-695f-4077-8308-cf100541a13c/terms")!

    private static func infoValue(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}

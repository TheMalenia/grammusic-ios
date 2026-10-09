import Foundation

/// Every `UserDefaults` key the app writes, in one place.
///
/// They used to be ~25 bare string literals scattered across a dozen files, and the cost was a
/// real privacy bug rather than untidiness: `wipeLocalAccountData()` erases per-account state by
/// listing keys by hand, so a key added anywhere else simply **survived sign-out** and leaked to
/// whoever logged in next. The user's search history did exactly that.
///
/// So the keys are split by lifetime, and the wipe is driven off `perAccount` rather than a
/// hand-maintained list. Adding a key to the wrong group is now a visible choice in one file
/// instead of an omission spread across the codebase.
enum StorageKeys {

    // MARK: - Per-account: erased on sign-out (deliberate or remote)

    /// Everything that belongs to the signed-in Telegram account and must not outlive it.
    ///
    /// **Add new per-account keys here.** Nothing else needs changing — `wipeLocalAccountData()`
    /// reads this list.
    static let perAccount: [String] = [
        recentlyPlayed,
        followedArtists,
        audioCountCache,
        pinnedKeys,
        seededPins,
        lastOpened,
        chatAudioCache,
        artistAudioCache,
        playCounts,
        playedTracks,
        playerState,
        audioCache,
        recentSearches,
        removedChats,
        removedProfiles,
        importedChats,
        newInChats,
        hasCompletedInitialSync,
        isLoggedIn,
        didOnboard,
        communityPromptSeen,
        mockSignedIn,
        demoMode,
        blockedChats,
        hiddenTracks,
        searchBots,
        defaultSearchSource,
    ]

    static let recentlyPlayed = "recentlyPlayed"
    static let followedArtists = "followedArtists"
    static let audioCountCache = "audioCountCache"
    static let pinnedKeys = "library.pinnedKeys"
    static let seededPins = "library.seededPins"
    static let lastOpened = "library.lastOpened"
    static let chatAudioCache = "n_chatAudioCache"
    static let artistAudioCache = "n_artistAudioCache"
    static let playCounts = "n_playCounts"
    static let playedTracks = "n_playedTracks"
    static let playerState = "n_playerState"
    /// The audio-cache ledger (what is on disk and how recently it was played).
    static let audioCache = "n_audioCache"
    /// Search history — the key whose absence from the old hand-written wipe list leaked one
    /// account's searches to the next person to sign in on the device.
    static let recentSearches = "n_recentSearches"
    static let removedChats = "n_removedChats"
    static let removedProfiles = "n_removedProfiles"
    static let importedChats = "n_importedChats"
    static let newInChats = "n_newInChats"
    static let hasCompletedInitialSync = "n_hasCompletedInitialSync"
    static let isLoggedIn = "n_isLoggedIn"
    /// Re-run the import onboarding for the next account.
    static let didOnboard = "n_didOnboard"
    /// ...and offer the community channel to them too.
    static let communityPromptSeen = "n_didSeeChannelPrompt"
    /// The mock backend's own session flag, and the demo-mode flag that decides the backend at
    /// launch. Both belong to whatever session was active.
    static let mockSignedIn = "n_mockSignedIn"
    static let demoMode = "n_demoMode"
    /// Chats/senders the user has blocked. Per-account: one account's block list must never
    /// decide what the *next* person to sign in on this device is allowed to see.
    static let hiddenTracks = "n_hiddenTracks"
    static let blockedChats = "n_blockedChats"

    static let searchBots = "n_searchBots"
    static let defaultSearchSource = "n_defaultSearchSource"

    // MARK: - Device preferences: survive sign-out

    /// The user's choices about *this app on this device*. Signing out of a Telegram account is
    /// not a reason to forget that someone prefers dark mode or has lyrics turned off.
    static let themeMode = "n_themeMode"
    static let accent = "n_accent"
    static let brand = "n_brand"
    static let artworkStyle = "n_artwork"
    static let saveSearchResults = "n_saveSearchResults"
    static let lyricsEnabled = "n_lyricsEnabled"
    static let aiTabEnabled = "n_aiTabEnabled"
    static let hasSeenAITab = "n_hasSeenAITab"
    static let autoplay = "n_autoplay"
    static let streamWhileDownloading = "streamWhileDownloading"
    /// Keep every played track permanently instead of caching it (Settings ▸ Storage).
    static let autoDownload = "n_autoDownloadPlayed"
    /// Byte budget for the evictable audio cache.
    static let audioCacheBudget = "n_audioCacheBudget"
    static let equalizerEnabled = "n_eq_enabled"
    static let equalizerPreset = "n_eq_preset"
    static let equalizerGains = "n_eq_gains"
    /// The version of the Terms of Use the person using this device has accepted. Stored as the
    /// accepted *version*, not a bool, so revised terms can re-prompt (App Review guideline 1.2
    /// requires the agreement be presented before sign-in). A device preference, not per-account:
    /// the agreement is with whoever holds the phone, and signing out of Telegram does not undo it.
    static let acceptedTermsVersion = "n_acceptedTermsVersion"
}

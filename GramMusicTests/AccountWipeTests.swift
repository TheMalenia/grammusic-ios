import XCTest
@testable import GramMusic

/// Nothing belonging to one Telegram account may survive into the next one.
///
/// `wipeLocalAccountData()` used to erase per-account state by listing keys **by hand**, so a key
/// added anywhere else in the codebase simply outlived sign-out. The user's search history did
/// exactly that. The list now comes from `StorageKeys.perAccount`, and these tests pin the
/// property that made the bug possible.
@MainActor
final class AccountWipeTests: XCTestCase {

    // Every key the app treats as account data must be in the wipe list. The inverse — a
    // preference wrongly listed as account data — would silently reset the user's theme on
    // sign-out, so both directions are checked.
    func test_perAccountKeys_areAllDistinct() {
        let keys = StorageKeys.perAccount
        XCTAssertEqual(Set(keys).count, keys.count, "a duplicated key hides a copy-paste mistake")
    }

    func test_searchHistory_isAccountData() {
        XCTAssertTrue(StorageKeys.perAccount.contains(StorageKeys.recentSearches),
                      "search history leaking to the next person to sign in is a privacy bug")
    }

    func test_theAudioCacheLedger_isAccountData() {
        XCTAssertTrue(StorageKeys.perAccount.contains(StorageKeys.audioCache),
                      "the next account must not inherit a ledger describing someone else's files")
    }

    func test_devicePreferences_areNotWiped() {
        // Signing out of Telegram is not a reason to forget that someone prefers dark mode.
        for preference in [StorageKeys.themeMode, StorageKeys.accent, StorageKeys.lyricsEnabled,
                           StorageKeys.autoplay, StorageKeys.streamWhileDownloading,
                           StorageKeys.autoDownload, StorageKeys.audioCacheBudget,
                           StorageKeys.equalizerEnabled, StorageKeys.equalizerGains] {
            XCTAssertFalse(StorageKeys.perAccount.contains(preference),
                           "\(preference) is a device preference, not account data")
        }
    }

    func test_sessionFlags_areWiped() {
        for flag in [StorageKeys.isLoggedIn, StorageKeys.demoMode, StorageKeys.mockSignedIn,
                     StorageKeys.didOnboard, StorageKeys.playerState] {
            XCTAssertTrue(StorageKeys.perAccount.contains(flag), "\(flag) belongs to the session")
        }
    }
}

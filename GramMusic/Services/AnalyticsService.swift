import Foundation
#if canImport(FirebaseAnalytics)
import FirebaseAnalytics
import FirebaseCore
#endif

/// A centralized wrapper for logging custom analytics events to Firebase.
/// This keeps Firebase imports out of the UI and business logic files.
struct AnalyticsService {
    
    /// Logs that *a* track was played — deliberately with **no metadata**.
    ///
    /// This previously sent `track_title` / `track_artist`: the names of files in the user's
    /// private Telegram chats, attached to a Firebase pseudonymous ID. That directly contradicted
    /// the privacy policy's claim that analytics data "cannot be used to identify you or access
    /// your personal Telegram content". Do not reintroduce per-track parameters here.
    static func logPlayTrack() {
        #if canImport(FirebaseAnalytics)
        guard FirebaseApp.app() != nil else { return }
        Analytics.logEvent("play_track", parameters: nil)
        #endif
    }
    
    /// Logs when a user views the lyrics sheet for a track.
    /// - Parameters:
    ///   - synced: Whether the lyrics are time-synced (LRC) or plain text.
    ///   - source: Where the lyrics came from (e.g., "file" or "lrclib").
    static func logViewLyrics(synced: Bool, source: String) {
        #if canImport(FirebaseAnalytics)
        guard FirebaseApp.app() != nil else { return }
        Analytics.logEvent("view_lyrics", parameters: [
            "synced": synced ? "true" : "false",
            "source": source
        ])
        #endif
    }
    
    /// Logs when a user adds a track to a playlist (or favorites/downloads).
    static func logAddToPlaylist() {
        #if canImport(FirebaseAnalytics)
        guard FirebaseApp.app() != nil else { return }
        Analytics.logEvent("add_to_playlist", parameters: nil)
        #endif
    }

    /// Logs when a user creates a new playlist.
    static func logCreatePlaylist() {
        #if canImport(FirebaseAnalytics)
        guard FirebaseApp.app() != nil else { return }
        Analytics.logEvent("create_playlist", parameters: nil)
        #endif
    }

    /// Logs when a user opens a chat view.
    static func logOpenChat() {
        #if canImport(FirebaseAnalytics)
        guard FirebaseApp.app() != nil else { return }
        Analytics.logEvent("open_chat", parameters: nil)
        #endif
    }

    /// Logs when a user opens the search tab.
    static func logOpenSearch() {
        #if canImport(FirebaseAnalytics)
        guard FirebaseApp.app() != nil else { return }
        Analytics.logEvent("open_search", parameters: nil)
        #endif
    }

    /// Logs when a user opens the library tab.
    static func logOpenLibrary() {
        #if canImport(FirebaseAnalytics)
        guard FirebaseApp.app() != nil else { return }
        Analytics.logEvent("open_library", parameters: nil)
        #endif
    }

    /// Logs when a user opens the settings view.
    static func logOpenSettings() {
        #if canImport(FirebaseAnalytics)
        guard FirebaseApp.app() != nil else { return }
        Analytics.logEvent("open_settings", parameters: nil)
        #endif
    }
}

import AppIntents
import Foundation

// MARK: - App Intents

struct PlayMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description: IntentDescription = IntentDescription("Resumes or starts playback in GramMusic.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        if let player = PlayerEngine.shared {
            if player.current != nil {
                player.resume()
            }
        }
        return .result()
    }
}

struct PauseMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause Music"
    static let description: IntentDescription = IntentDescription("Pauses audio playback in GramMusic.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        PlayerEngine.shared?.pause()
        return .result()
    }
}

struct TogglePlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Toggle Play/Pause"
    static let description: IntentDescription = IntentDescription("Toggles play/pause state in GramMusic.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        PlayerEngine.shared?.togglePlayPause()
        return .result()
    }
}

struct SkipNextIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let description: IntentDescription = IntentDescription("Skips to the next track in the queue.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        PlayerEngine.shared?.next()
        return .result()
    }
}

struct SkipPreviousIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static let description: IntentDescription = IntentDescription("Skips to the previous track.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        PlayerEngine.shared?.previous()
        return .result()
    }
}

// MARK: - App Shortcuts Provider

struct GramMusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: [
                "Play music in \(.applicationName)",
                "Play on \(.applicationName)",
                "Resume on \(.applicationName)",
                "Play music on \(.applicationName)",
                "Play \(.applicationName)"
            ],
            shortTitle: "Play Music",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PauseMusicIntent(),
            phrases: [
                "Pause on \(.applicationName)",
                "Pause music on \(.applicationName)",
                "Stop \(.applicationName)",
                "Pause \(.applicationName)"
            ],
            shortTitle: "Pause Music",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: SkipNextIntent(),
            phrases: [
                "Next song on \(.applicationName)",
                "Skip track on \(.applicationName)",
                "Next on \(.applicationName)",
                "Next track on \(.applicationName)"
            ],
            shortTitle: "Next Track",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: SkipPreviousIntent(),
            phrases: [
                "Previous song on \(.applicationName)",
                "Previous track on \(.applicationName)",
                "Previous on \(.applicationName)"
            ],
            shortTitle: "Previous Track",
            systemImageName: "backward.fill"
        )
    }
}

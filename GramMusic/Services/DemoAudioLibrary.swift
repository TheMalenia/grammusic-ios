import Foundation

/// The bundled audio the **mock** backend serves — the one thing standing between demo mode and
/// "this is not a music player".
///
/// Mock mode used to synthesize a sine tone capped at **8 seconds** per track. That is enough to
/// prove the player *works*, and nowhere near enough to demonstrate the feature the player exists
/// for: App Review rejected the app under guideline 2.5.4 ("unable to locate any features that
/// require persistent audio") because a reviewer in demo mode pressed play, went to the Home
/// Screen, and heard a four-second beep stop. Persistent background audio cannot be demonstrated
/// with audio that isn't persistent.
///
/// So demo mode now plays ~15 minutes of real, public-domain piano across six clips. They are
/// bundled (`Resources/DemoAudio`), so this works with no network, no Telegram, and no account —
/// which is exactly the situation a reviewer is in. See `CREDITS.md` there for provenance.
enum DemoAudioLibrary {

    struct Clip {
        let resource: String
        let title: String
        let performer: String
        let album: String
        /// Real duration of the bundled file, in seconds. It must match the file: this is what the
        /// scrubber, the queue and the Lock Screen display before the asset has loaded.
        let duration: Int
    }

    /// Order is stable — `MockTelegramBackend` rotates through it per chat, so different chats
    /// lead with different tracks instead of every chat looking like a copy of the last.
    static let clips: [Clip] = [
        Clip(resource: "demo1", title: "Aria",
             performer: "Kimiko Ishizaka", album: "Goldberg Variations", duration: 180),
        Clip(resource: "demo2", title: "Variatio 1 a 1 Clav.",
             performer: "Kimiko Ishizaka", album: "Goldberg Variations", duration: 115),
        Clip(resource: "demo3", title: "Variatio 4 a 1 Clav.",
             performer: "Kimiko Ishizaka", album: "Goldberg Variations", duration: 68),
        Clip(resource: "demo4", title: "Contrapunctus 1",
             performer: "Kimiko Ishizaka", album: "The Art of the Fugue", duration: 180),
        Clip(resource: "demo5", title: "Contrapunctus 2",
             performer: "Kimiko Ishizaka", album: "The Art of the Fugue", duration: 155),
        Clip(resource: "demo6", title: "Contrapunctus 5",
             performer: "Kimiko Ishizaka", album: "The Art of the Fugue", duration: 180)
    ]

    /// The bundled file for a clip, or `nil` when the resource is missing — which happens in the
    /// unit-test bundle, where no audio ships. Callers fall back to the tone generator rather than
    /// failing, so tests that only care about the *shape* of playback keep working.
    static func url(for clip: Clip) -> URL? {
        Bundle.main.url(forResource: clip.resource, withExtension: "mp3")
    }

    static func clip(at index: Int) -> Clip {
        clips[((index % clips.count) + clips.count) % clips.count]
    }
}

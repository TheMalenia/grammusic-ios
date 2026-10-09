import Foundation
import Observation

/// Short-lived confirmation shared by the browsing screens, sheets, and hosted player.
@MainActor @Observable
final class NActionFeedback {
    @ObservationIgnored private var announcedID: UUID?
    private(set) var id = UUID()
    private(set) var message: String?
    private(set) var offersQueue = false
    private(set) var undo: (() -> Void)?

    func show(_ message: String, offersQueue: Bool = false, undo: (() -> Void)? = nil) {
        id = UUID()
        self.message = message
        self.offersQueue = offersQueue
        self.undo = undo
    }

    func dismiss(ifMatching expectedID: UUID? = nil) {
        guard expectedID == nil || expectedID == id else { return }
        message = nil
        undo = nil
        offersQueue = false
    }

    func takeAnnouncement() -> String? {
        guard announcedID != id, let message else { return nil }
        announcedID = id
        return message
    }

    func undoLastAction() {
        let action = undo
        dismiss()
        action?()
    }

    func enqueue(_ track: AudioTrack, in player: PlayerEngine, next: Bool = false, fromSearch: Bool = false) {
        if next { player.playNext(track, fromSearch: fromSearch) } else { player.addToQueue(track, fromSearch: fromSearch) }
    }

    func toggleFavorite(_ track: AudioTrack, in telegram: TelegramService) {
        telegram.toggleFavorite(track)
    }
}

// Preserve the bare engine APIs for background callers and previews.
extension PlayerEngine {
    func addToQueue(_ track: AudioTrack, feedback: NActionFeedback?, fromSearch: Bool = false) {
        if let feedback { feedback.enqueue(track, in: self, fromSearch: fromSearch) }
        else { addToQueue(track, fromSearch: fromSearch) }
    }

    func playNext(_ track: AudioTrack, feedback: NActionFeedback?, fromSearch: Bool = false) {
        if let feedback { feedback.enqueue(track, in: self, next: true, fromSearch: fromSearch) }
        else { playNext(track, fromSearch: fromSearch) }
    }
}

import Foundation

/// Actionable search copy; transport diagnostics stay in the controller's raw error.
struct MusicSearchFailure: Equatable {
    let title: String
    let message: String
    let canRetry: Bool
    let isPagination: Bool

    init(error: Error, source: MusicSearchSource, isPagination: Bool = false) {
        self.isPagination = isPagination
        let raw = error.localizedDescription
        let text = raw.uppercased()
        let network = error as NSError
        if text.contains("FLOOD_WAIT") || text.contains("TOO MANY") {
            title = "Search needs a short break"
            message = text.contains("FLOOD_WAIT")
                ? "Telegram is limiting searches right now. Wait a little before searching again."
                : raw
            canRetry = false
        } else if text.contains("502") || text.contains("BOT_RESPONSE_TIMEOUT") ||
                    text.contains("BOT IS NOT RESPONDING") || text.contains("TIMED OUT") ||
                    text.contains("TIMEOUT") || (network.domain == NSURLErrorDomain && network.code == URLError.timedOut.rawValue) {
            title = source.isTelegram ? "Search timed out" : "Bot timed out"
            message = isPagination
                ? "Your loaded songs are still here. \(source.label) didn't answer this page in time. Try loading it again."
                : "\(source.label) didn't answer in time. Try again, or choose another search source."
            canRetry = true
        } else if text.contains("INLINE") && (text.contains("DISABLED") || text.contains("SUPPORT")) {
            title = "This bot can't search here"
            message = "\(source.label) doesn't support inline music search. Choose another bot in Search settings."
            canRetry = false
        } else if text.contains("OFFLINE") || text.contains("INTERNET CONNECTION") ||
                    text.contains("NO CONNECTION") || text.contains("NOT CONNECTED") ||
                    text.contains("NETWORK UNAVAILABLE") ||
                    (network.domain == NSURLErrorDomain && network.code == URLError.notConnectedToInternet.rawValue) {
            title = "You're offline"
            message = "Connect to the internet to search \(source.label). You can still search saved music in the Telegram tab."
            canRetry = true
        } else if TelegramError.isRetryable(error) {
            title = isPagination ? "Couldn't load more songs" : "Search couldn't connect"
            message = isPagination
                ? "Your loaded songs are still here. Try loading the next page again."
                : "The connection to \(source.label) was interrupted. Try again in a moment."
            canRetry = true
        } else if !source.isTelegram && (text.contains("BOT_RESPONSE") || text.contains("BOT ERROR") || text.contains("BOT FAILED")) {
            title = isPagination ? "Bot couldn't load this page" : "Bot couldn't complete the search"
            message = isPagination
                ? "Your loaded songs are still here. \(source.label) returned an error for this page. Try again later, or choose another search source."
                : "\(source.label) returned an error while searching. Try again later, or choose another search source."
            canRetry = true
        } else {
            title = isPagination ? "Couldn't load more songs" : "Couldn't search \(source.label)"
            message = isPagination
                ? "Your loaded songs are still here. Try loading the next page again."
                : "Try again, or choose another search source."
            canRetry = true
        }
    }
}

import Foundation

/// Saved Messages has one chat identity per authenticated session. Share its preparation
/// across queries, pages, and search screens without retaining it across account changes.
@MainActor
final class InlineMusicSearchContext {
    private var chatID: Int64?
    private var generation = 0
    private var pending: (id: UUID, task: Task<Int64, Error>)?

    func resolve(load: @escaping @MainActor () async throws -> Int64) async throws -> Int64 {
        try Task.checkCancellation()
        if let chatID { return chatID }
        let requestGeneration = generation
        let request: (id: UUID, task: Task<Int64, Error>)
        if let pending { request = pending }
        else {
            request = (UUID(), Task { try await load() })
            pending = request
        }
        do {
            let resolved = try await request.task.value
            guard generation == requestGeneration else { throw CancellationError() }
            if pending?.id == request.id { pending = nil }
            guard resolved != 0 else {
                throw TelegramError.backend("Couldn't prepare the Saved Messages search context. Try again.")
            }
            chatID = resolved
            try Task.checkCancellation()
            return resolved
        } catch {
            if pending?.id == request.id { pending = nil }
            throw error
        }
    }

    func clear() {
        generation += 1
        chatID = nil
        pending?.task.cancel()
        pending = nil
    }
}

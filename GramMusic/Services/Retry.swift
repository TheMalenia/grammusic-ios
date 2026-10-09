import Foundation

/// Exponential-backoff retry for the network paths (login, downloads, playback loads).
///
/// The rule this encodes: **a transient failure is not an error yet.** Telegram over a flaky
/// mobile link routinely drops a request that succeeds a second later, and surfacing the first
/// one as red text teaches the user the app is broken when it isn't. So every network call the
/// user is waiting on goes through here, and only the *last* failure is allowed to reach the UI.
///
/// The two halves are deliberately separable so they can be tested without waiting in real time:
/// `delay(forAttempt:policy:randomness:)` is pure, and `run` takes an injectable `sleep`.
enum Retry {

    /// How hard to try, and how long to wait between attempts.
    struct Policy: Sendable, Equatable {
        /// Total attempts including the first. `1` means "no retry".
        var attempts: Int
        var initialDelay: Duration
        var multiplier: Double
        var maxDelay: Duration
        /// Fraction of the delay to randomise by (0…1), so parallel retries don't align.
        var jitter: Double

        init(attempts: Int, initialDelay: Duration, multiplier: Double = 2,
             maxDelay: Duration = .seconds(8), jitter: Double = 0.25) {
            self.attempts = max(1, attempts)
            self.initialDelay = initialDelay
            self.multiplier = multiplier
            self.maxDelay = maxDelay
            self.jitter = min(max(jitter, 0), 1)
        }

        /// The user is staring at a spinner — retry quickly and give up before they do.
        static let auth = Policy(attempts: 3, initialDelay: .milliseconds(700), maxDelay: .seconds(3))
        /// Background work with nobody watching: patient, spread out.
        static let download = Policy(attempts: 3, initialDelay: .seconds(2), maxDelay: .seconds(15))
        /// Audio is already silent while we retry, so stay tight.
        static let playback = Policy(attempts: 3, initialDelay: .milliseconds(500), maxDelay: .seconds(2))
        /// One-shot: used where a caller wants the plumbing (per-attempt timeout) but no retry.
        static let none = Policy(attempts: 1, initialDelay: .zero)
    }

    /// Backoff before attempt `attempt` (1-based; attempt 1 never waits). Pure, so the schedule
    /// is unit-testable — pass `randomness` to pin the jitter.
    static func delay(forAttempt attempt: Int, policy: Policy, randomness: Double = .random(in: 0...1)) -> Duration {
        guard attempt > 1 else { return .zero }
        let steps = Double(attempt - 2)
        let base = policy.initialDelay.seconds * pow(policy.multiplier, steps)
        let capped = min(base, policy.maxDelay.seconds)
        // Jitter only ever *shortens* the wait, so `maxDelay` stays a real ceiling.
        let factor = 1 - policy.jitter * min(max(randomness, 0), 1)
        return .seconds(max(0, capped * factor))
    }

    /// Run `operation`, retrying while `isRetryable` says the failure is worth another go.
    ///
    /// A `CancellationError` always propagates immediately — cancellation is a decision, not a
    /// failure. The final error is rethrown unchanged so the caller keeps its message.
    /// `isolation` makes this run **in the caller's** isolation domain rather than transferring
    /// the closures out of it. Without it, every call from a `@MainActor` type — which is all of
    /// them — sends a non-Sendable closure across an isolation boundary, and region-based
    /// isolation flags it as a potential data race (an error under the Swift 6 language mode).
    /// Inheriting the caller's actor is also what the code always *meant*: `operation` captures
    /// main-actor state and expects to run there.
    static func run<T>(_ policy: Policy = .auth,
                       isolation: isolated (any Actor)? = #isolation,
                       isRetryable: (Error) -> Bool = { TelegramError.isRetryable($0) },
                       sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                       operation: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < policy.attempts, isRetryable(error), !Task.isCancelled else { throw error }
                attempt += 1
                try await sleep(delay(forAttempt: attempt, policy: policy))
            }
        }
    }
}

extension Duration {
    /// Seconds as a `Double`. `Duration` only exposes an exact `(seconds, attoseconds)` pair.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

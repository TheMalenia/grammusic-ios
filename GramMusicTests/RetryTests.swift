import XCTest
@testable import GramMusic

/// The retry layer, tested where it actually matters: the *classification* (is this failure worth
/// another go?) and the *schedule* (how long do we wait). Both are pure, so none of these tests
/// sleep — `Retry.run` takes an injectable `sleep`, and `delay(forAttempt:)` takes its randomness.
final class RetryTests: XCTestCase {

    // MARK: - Classification

    // A wrong code or a bad number is the user's to fix — retrying it just delays the bad news.
    func test_userFaultErrors_areNotRetryable() {
        XCTAssertFalse(TelegramError.backend("Wrong code. Please try again.").isRetryable)
        XCTAssertFalse(TelegramError.unsupportedFormat("Opus").isRetryable)
        XCTAssertFalse(TelegramError.deleted("Song").isRetryable)
        XCTAssertFalse(TelegramError.missingCredentials.isRetryable)
    }

    // A dropped link is not an error yet — it's the normal state of a phone on a train.
    func test_transientAndNotReady_areRetryable() {
        XCTAssertTrue(TelegramError.transient("Connection timed out.").isRetryable)
        XCTAssertTrue(TelegramError.notReady.isRetryable)
    }

    func test_urlErrors_classifiedByKind() {
        XCTAssertTrue(TelegramError.isRetryable(URLError(.networkConnectionLost)))
        XCTAssertTrue(TelegramError.isRetryable(URLError(.notConnectedToInternet)))
        XCTAssertTrue(TelegramError.isRetryable(URLError(.timedOut)))
        // Not a network condition — a second attempt gets the same 404.
        XCTAssertFalse(TelegramError.isRetryable(URLError(.badURL)))
    }

    func test_cancellation_isNeverRetryable() {
        XCTAssertFalse(TelegramError.isRetryable(CancellationError()))
    }

    func test_unknownErrors_treatedAsPermanent() {
        struct Mystery: Error {}
        XCTAssertFalse(TelegramError.isRetryable(Mystery()))
    }

    // MARK: - Backoff schedule

    // The first attempt happens now; only the retries wait.
    func test_firstAttempt_neverWaits() {
        let policy = Retry.Policy(attempts: 3, initialDelay: .seconds(1))
        XCTAssertEqual(Retry.delay(forAttempt: 1, policy: policy, randomness: 0).seconds, 0)
    }

    func test_delayGrowsExponentially_andIsCapped() {
        let policy = Retry.Policy(attempts: 6, initialDelay: .seconds(1), multiplier: 2,
                                  maxDelay: .seconds(4), jitter: 0)
        // attempt 2 → 1s, 3 → 2s, 4 → 4s, then the cap holds it at 4s.
        XCTAssertEqual(Retry.delay(forAttempt: 2, policy: policy, randomness: 0).seconds, 1, accuracy: 0.001)
        XCTAssertEqual(Retry.delay(forAttempt: 3, policy: policy, randomness: 0).seconds, 2, accuracy: 0.001)
        XCTAssertEqual(Retry.delay(forAttempt: 4, policy: policy, randomness: 0).seconds, 4, accuracy: 0.001)
        XCTAssertEqual(Retry.delay(forAttempt: 5, policy: policy, randomness: 0).seconds, 4, accuracy: 0.001)
    }

    // Jitter must only ever shorten the wait, so `maxDelay` stays a real ceiling rather than a
    // number the schedule sometimes overshoots.
    func test_jitter_onlyShortens() {
        let policy = Retry.Policy(attempts: 4, initialDelay: .seconds(2), multiplier: 2,
                                  maxDelay: .seconds(10), jitter: 0.5)
        let full = Retry.delay(forAttempt: 2, policy: policy, randomness: 0).seconds
        let jittered = Retry.delay(forAttempt: 2, policy: policy, randomness: 1).seconds
        XCTAssertEqual(full, 2, accuracy: 0.001)
        XCTAssertEqual(jittered, 1, accuracy: 0.001)
        XCTAssertLessThanOrEqual(jittered, full)
    }

    // MARK: - run()

    func test_retriesTransientFailure_thenSucceeds() async throws {
        var calls = 0
        var slept: [Duration] = []
        let value = try await Retry.run(.auth, sleep: { slept.append($0) }) { () -> String in
            calls += 1
            if calls < 3 { throw TelegramError.transient("dropped") }
            return "ok"
        }
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(slept.count, 2, "one backoff per retry, none before the first attempt")
    }

    func test_permanentFailure_isNotRetried() async {
        var calls = 0
        do {
            _ = try await Retry.run(.auth, sleep: { _ in }) { () -> String in
                calls += 1
                throw TelegramError.backend("Wrong code. Please try again.")
            }
            XCTFail("expected the error to propagate")
        } catch {
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "Wrong code. Please try again.")
        }
        XCTAssertEqual(calls, 1, "a user-fault error must reach the user on the first attempt")
    }

    func test_givesUpAfterPolicyAttempts_andRethrowsTheLastError() async {
        var calls = 0
        let policy = Retry.Policy(attempts: 3, initialDelay: .milliseconds(1))
        do {
            _ = try await Retry.run(policy, sleep: { _ in }) { () -> String in
                calls += 1
                throw TelegramError.transient("attempt \(calls)")
            }
            XCTFail("expected the error to propagate")
        } catch {
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "attempt 3",
                           "the caller must see the final failure, not the first")
        }
        XCTAssertEqual(calls, 3)
    }

    // Cancellation is a decision, not a failure: it must escape immediately rather than being
    // absorbed into a retry loop that keeps running after the user moved on.
    func test_cancellation_propagatesImmediately() async {
        var calls = 0
        do {
            _ = try await Retry.run(.download, sleep: { _ in }) { () -> String in
                calls += 1
                throw CancellationError()
            }
            XCTFail("expected cancellation to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(calls, 1)
    }

    func test_noRetryPolicy_makesExactlyOneAttempt() async {
        var calls = 0
        _ = try? await Retry.run(.none, sleep: { _ in }) { () -> String in
            calls += 1
            throw TelegramError.transient("dropped")
        }
        XCTAssertEqual(calls, 1)
    }
}

import XCTest
@testable import GramMusic

/// Which failures are allowed to reach the user.
///
/// `lastError` is read by the playback banner, so anything written there interrupts whatever the
/// user is doing — including listening to music. Background housekeeping (the chat-list refresh,
/// the cover warm-up) used to report there, which is how "Connection timed out — check your
/// internet" appeared over a perfectly healthy, connected playback session.
@MainActor
final class ErrorSurfaceTests: XCTestCase {

    private func makeService() -> TelegramService {
        TelegramService(backend: MockTelegramBackend())
    }

    // MARK: - Surfaces

    func test_userFacingFailure_isReported() async {
        let service = makeService()
        let ok = await service.run(surface: .user) { throw TelegramError.backend("Couldn't send that.") }

        XCTAssertFalse(ok)
        XCTAssertEqual(service.lastError, "Couldn't send that.")
    }

    // The headline rule: background work never interrupts the user.
    func test_backgroundFailure_isNotReported() async {
        let service = makeService()
        let ok = await service.run(surface: .log) { throw TelegramError.backend("Chat refresh failed.") }

        XCTAssertFalse(ok)
        XCTAssertNil(service.lastError, "background housekeeping must not raise the playback banner")
    }

    func test_backgroundTimeout_isNotReported() async {
        let service = makeService()
        let ok = await service.run(timeout: .milliseconds(50), surface: .log) {
            try await Task.sleep(for: .seconds(5))
        }

        XCTAssertFalse(ok)
        XCTAssertNil(service.lastError,
                     "a background job outrunning its deadline says nothing about the user's connection")
    }

    func test_userFacingTimeout_isReportedAsATimeout() async {
        let service = makeService()
        let ok = await service.run(timeout: .milliseconds(50), surface: .user) {
            try await Task.sleep(for: .seconds(5))
        }

        XCTAssertFalse(ok)
        XCTAssertEqual(service.lastError,
                       "Connection timed out. Please check your internet or VPN connection and try again.")
    }

    func test_success_returnsTrueAndLeavesTheBannerAlone() async {
        let service = makeService()
        service.lastError = nil
        let ok = await service.run(surface: .user) { }

        XCTAssertTrue(ok)
        XCTAssertNil(service.lastError)
    }

    // MARK: - The other half of the bug

    /// The timeout doesn't just *report* a failure — it cancels the task group, so the work is
    /// killed partway through. That is why a deadline has to fit the job: wrapping the chat probe
    /// (minutes of work by design) in 15 seconds silently left the chat list half-probed, on top
    /// of the spurious banner.
    func test_timeoutCancelsTheWorkItWraps() async {
        let service = makeService()
        var completed = false
        _ = await service.run(timeout: .milliseconds(50), surface: .log) {
            try await Task.sleep(for: .seconds(2))
            completed = true
        }

        XCTAssertFalse(completed, "a deadline shorter than the work destroys the work, not just the wait")
    }

    /// Cancellation is a normal concurrency event (a parent task going away), never a user-visible
    /// failure — on either surface.
    func test_cancellationIsNeverReported() async {
        let service = makeService()
        let ok = await service.run(surface: .user) { throw CancellationError() }

        XCTAssertFalse(ok)
        XCTAssertNil(service.lastError)
    }
}

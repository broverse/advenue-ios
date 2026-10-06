import Foundation
import XCTest

@testable import Advenue
@testable import AdvenuePlatform

final class AttWaitTests: XCTestCase {
  /// Scripted status reader: yields the next value per call, then repeats
  /// the last one — a status that never resolves keeps answering
  /// `notDetermined`, exactly like a user who never sees the prompt.
  /// `Locked` because the wait takes `@Sendable` closures.
  private func reader(_ values: TrackingAuthorization...) -> @Sendable () -> TrackingAuthorization {
    let i = Locked(0)
    return {
      var v = TrackingAuthorization.notDetermined
      i.mutate { idx in v = values[min(idx, values.count - 1)]; idx += 1 }
      return v
    }
  }

  func testAlreadyDeterminedDoesNotSleep() async {
    let sleeps = Locked(0)
    let end = await waitForAttDetermination(
      status: reader(.authorized), pollMs: 500, timeoutMs: 60_000,
      sleep: { _ in sleeps.mutate { $0 += 1 } })
    XCTAssertEqual(end, .authorized)
    XCTAssertEqual(sleeps.value, 0, "a determined status never waits")
  }

  func testDeniedIsDeterminedToo() async {
    let sleeps = Locked(0)
    let end = await waitForAttDetermination(
      status: reader(.denied), pollMs: 500, timeoutMs: 60_000,
      sleep: { _ in sleeps.mutate { $0 += 1 } })
    XCTAssertEqual(end, .denied)
    XCTAssertEqual(sleeps.value, 0, "denied is an answer, not an absence of one")
  }

  func testReturnsAsSoonAsStatusResolves() async {
    let sleeps = Locked(0)
    let end = await waitForAttDetermination(
      status: reader(.notDetermined, .notDetermined, .denied),
      pollMs: 500, timeoutMs: 60_000,
      sleep: { _ in sleeps.mutate { $0 += 1 } })
    XCTAssertEqual(end, .denied)
    XCTAssertEqual(sleeps.value, 2, "must return on resolution, not at timeout")
  }

  func testTimeoutReturnsNotDetermined() async {
    let elapsed = Locked(0)
    let end = await waitForAttDetermination(
      status: reader(.notDetermined), pollMs: 500, timeoutMs: 1_500,
      sleep: { ms in elapsed.mutate { $0 += ms } })
    XCTAssertEqual(end, .notDetermined)
    XCTAssertGreaterThanOrEqual(elapsed.value, 1_500)
    XCTAssertLessThan(elapsed.value, 1_500 + 500 + 1, "must not overshoot by more than one poll")
  }

  func testCancellationExitsEarly() async {
    // Hoisted: calling self.reader inside the Task would capture XCTestCase
    // across the concurrency domain; the @Sendable value itself is fine.
    let status = reader(.notDetermined)
    let task = Task {
      await waitForAttDetermination(
        status: status, pollMs: 500, timeoutMs: 120_000,
        sleep: { ms in try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) })
    }
    task.cancel()
    let end = await task.value
    XCTAssertEqual(end, .notDetermined)
    // The real contract is returning without waiting 120 s. No wall-clock
    // assertion — flaky by construction; the test finishing at all proves it.
  }

  func testWaitIntervalIsClamped() {
    // The clamp rule lives on the config as a pure function.
    XCTAssertEqual(AdvenueConfig.clampedAttWait(130), 120)
    XCTAssertEqual(AdvenueConfig.clampedAttWait(-5), 0)
    XCTAssertEqual(AdvenueConfig.clampedAttWait(0), 0)
    XCTAssertEqual(AdvenueConfig.clampedAttWait(60), 60)
  }

  func testWaitIntervalDefaultsToOff() {
    XCTAssertEqual(
      AdvenueConfig(apiKey: "apk_test").attConsentWaitingInterval, 0,
      "the wait is opt-in; unset means today's behaviour")
  }
}

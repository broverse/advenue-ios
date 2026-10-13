import Foundation
import XCTest

@testable import AdvenueCore

/// Holds the FIRST call until released; later calls pass straight through.
actor GatedCoreTransport: EventTransport {
  private(set) var sends = 0
  private var released = false
  private var waiter: CheckedContinuation<Void, Never>?
  func send(_ events: [ClientEvent]) async throws {
    sends += 1
    if released || sends > 1 { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
}

/// Holds the FIRST SKAN update at "Apple" until released.
actor GatedSkanReporter: SkanReporter {
  private(set) var calls = 0
  private var released = false
  private var waiter: CheckedContinuation<Void, Never>?
  nonisolated func register() {}
  func update(fine: Int, coarse: CoarseValue, lockWindow: Bool) async throws {
    calls += 1
    if released || calls > 1 { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
}

/// Spec 3 §7, the engine and pipe halves of `resetInstall()`.
final class ResetInstallCoreTests: XCTestCase {
  private func engine(
    _ store: MemoryStore, transport: (any EventTransport)? = nil
  ) -> AdvenueEngine {
    AdvenueEngine(
      config: EngineConfig(
        apiKey: "apk_test", platform: "ios", deviceId: "d1", installationId: "inst-old",
        requireConsent: false),
      store: store, clock: FixedClock(ms: 0),
      scheduler: RecordingScheduler(), uuid: SequentialUUIDs(prefix: "ev"),
      transport: transport)
  }

  private func until(
    timeout: TimeInterval = 5, _ condition: @Sendable () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("condition never became true within \(timeout)s")
  }

  /// K4: an engine whose reset arrives after the SDK changed hands (a stop or a
  /// re-initialize while it drained) stops working but leaves the store alone:
  /// the keys now belong to the instance that replaced it.
  func testAResetThatNoLongerOwnsTheSdkLeavesTheStoreAlone() async {
    let store = MemoryStore()
    store.preload(INSTALL_SENT_KEY, "1")
    store.preload(SESSION_STATE_KEY, "{}")
    let e = engine(store)

    await e.resetInstallState(stillOwned: { false })

    XCTAssertEqual(store.raw(INSTALL_SENT_KEY), "1")
    XCTAssertEqual(store.raw(SESSION_STATE_KEY), "{}")
    // And the engine is finished all the same.
    await e.track("after", properties: nil, type: "custom")
    let pending = await e.pendingEvents()
    XCTAssertTrue(pending.isEmpty)
  }

  func testAResetThatStillOwnsTheSdkClearsTheInstall() async {
    let store = MemoryStore()
    store.preload(INSTALL_SENT_KEY, "1")
    store.preload(SESSION_STATE_KEY, "{}")
    let e = engine(store)

    await e.resetInstallState(stillOwned: { true })

    XCTAssertNil(store.raw(INSTALL_SENT_KEY))
    XCTAssertNil(store.raw(SESSION_STATE_KEY))
  }

  /// K10: a SKAN update already out at Apple when the reset lands must not
  /// write the old installation's state back after the facade removed it.
  func testASkanUpdateInFlightAcrossTheResetDoesNotRewriteTheOldState() async throws {
    let store = MemoryStore()
    let e = engine(store)
    let reporter = GatedSkanReporter()
    await e.enableSkan(
      mapper: try ConversionValueMapper(
        ConversionValueConfig(rules: [ConversionValueRule(fineValue: 10, events: ["signup"])])),
      currency: nil, installationId: "inst-old", reporter: reporter)
    let key = skanStateKey(installationId: "inst-old")

    let recording = Task { await e.recordSkan(event: "signup") }
    try await until { await reporter.calls == 1 }
    await e.resetInstallState()
    // What the facade does once the drain is over.
    store.removeObject(forKey: key)
    await reporter.release()
    await recording.value

    XCTAssertNil(store.raw(key), "the old installation's SKAN state was written back")
  }

  /// K11: `shutdownAndWait` waits for the command already running. While the
  /// transport holds a flush it has not returned; once released, it does.
  func testShutdownAndWaitWaitsForTheCommandInFlight() async throws {
    let transport = GatedCoreTransport()
    let e = engine(MemoryStore(), transport: transport)
    let pipe = CommandPipe(engine: e)
    pipe.submit(.track(name: "a", properties: nil, type: "custom"))
    pipe.submit(.flush)
    try await until { await transport.sends == 1 }

    let done = Locked(false)
    let waiting = Task {
      await pipe.shutdownAndWait()
      done.mutate { $0 = true }
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertFalse(done.value, "returned while a command was still running")

    await transport.release()
    await waiting.value
    XCTAssertTrue(done.value)
  }
}

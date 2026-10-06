import Foundation
import XCTest

@testable import AdvenueCore

/// F-SDK-3: the install is the first package of an installation. It is stamped
/// when the launch began, not when enrichment finished, and nothing is sent
/// ahead of it.
final class InstallHoldTests: XCTestCase {
  private func engine(
    _ store: MemoryStore, _ clock: MutableClock, transport: ScriptedTransport,
    requireConsent: Bool = false
  ) -> AdvenueEngine {
    AdvenueEngine(
      config: EngineConfig(
        apiKey: "apk_test", platform: "ios", deviceId: "d1", requireConsent: requireConsent),
      store: store, clock: clock,
      scheduler: RecordingScheduler(), uuid: SequentialUUIDs(prefix: "ev"),
      transport: transport)
  }

  func testFlushIsHeldUntilTheInstallIsRecordedAndTheInstallGoesFirst() async {
    let store = MemoryStore()
    let clock = MutableClock()
    clock.ms = 1_000_000
    let transport = ScriptedTransport([])
    let e = engine(store, clock, transport: transport)

    await e.beginInstall(holdMs: 5_000)
    await e.notifyForeground()
    clock.ms += 500
    await e.track("example_purchase")
    await e.flush()
    let sentBeforeInstall = await transport.requests
    XCTAssertEqual(sentBeforeInstall, [], "nothing may be sent ahead of the install")

    clock.ms += 2_500  // enrichment finished
    await e.trackInstall(adservicesToken: nil)
    await e.flush()

    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1, "install and the held events ride one batch")
    let events = await e.pendingEvents()
    XCTAssertTrue(events.isEmpty)
    // ev-1 = the session id, ev-2 = session_start, ev-3 = example_purchase,
    // ev-4 = install.
    XCTAssertEqual(requests.first, ["ev-4", "ev-2", "ev-3"], "the install leads the batch")
  }

  func testTheInstallIsStampedWithTheLaunchTimeNotTheEnrichmentTime() async {
    let store = MemoryStore()
    let clock = MutableClock()
    clock.ms = 1_700_000_000_000
    let e = engine(store, clock, transport: ScriptedTransport([]))

    await e.beginInstall(holdMs: 5_000)
    await e.notifyForeground()
    clock.ms += 3_000
    await e.trackInstall(adservicesToken: nil)

    let events = await e.pendingEvents()
    let install = events.first { $0.type == "install" }
    let start = events.first { $0.name == "session_start" }
    XCTAssertEqual(install?.timestamp, EventEncoding.iso8601(ms: 1_700_000_000_000))
    XCTAssertNotNil(start)
    XCTAssertLessThanOrEqual(install!.timestamp, start!.timestamp)
  }

  /// The ATT wait ran across a suspension: the launch hold lapsed on the wall
  /// clock while enrichment was still ahead. Re-arming it keeps the events
  /// behind the install for that last stretch.
  func testExtendingALapsedHoldHoldsFlushesAgain() async {
    let store = MemoryStore()
    let clock = MutableClock()
    clock.ms = 1_000_000
    let transport = ScriptedTransport([])
    let e = engine(store, clock, transport: transport)

    await e.beginInstall(holdMs: 5_000)
    await e.notifyForeground()
    clock.ms += 600_000  // suspended through the wait; the hold lapsed
    await e.extendInstallHold(holdMs: 5_000)
    await e.track("example_purchase")
    await e.flush()
    let sentBeforeInstall = await transport.requests
    XCTAssertEqual(sentBeforeInstall, [], "the re-armed hold must keep events behind the install")

    await e.trackInstall(adservicesToken: nil)
    await e.flush()
    let requests = await transport.requests
    XCTAssertEqual(requests.first?.first, "ev-4", "the install leads the batch")
  }

  func testExtendingAfterTheInstallIsANoOp() async {
    let store = MemoryStore()
    let clock = MutableClock()
    clock.ms = 1_000_000
    let transport = ScriptedTransport([])
    let e = engine(store, clock, transport: transport)

    await e.beginInstall(holdMs: 5_000)
    await e.trackInstall(adservicesToken: nil)
    await e.extendInstallHold(holdMs: 5_000)
    await e.track("after")
    await e.flush()

    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1, "a recorded install leaves nothing to hold for")
  }

  /// A lost enrichment task must never strand the queue.
  func testTheHoldLapsesAtItsCeiling() async {
    let store = MemoryStore()
    let clock = MutableClock()
    clock.ms = 1_000_000
    let transport = ScriptedTransport([])
    let e = engine(store, clock, transport: transport)

    await e.beginInstall(holdMs: 5_000)
    await e.track("example_purchase")
    clock.ms += 5_000
    await e.flush()

    let requests = await transport.requests
    XCTAssertEqual(requests, [["ev-1"]])
  }

  /// With consent required and not given, the install is deferred, possibly
  /// for good — the hold must not outlive that decision.
  func testAConsentDeferredInstallReleasesTheHold() async {
    let store = MemoryStore()
    store.preload(CONSENT_KEY, "granted")
    let clock = MutableClock()
    clock.ms = 1_000_000
    let transport = ScriptedTransport([])
    let e = engine(store, clock, transport: transport, requireConsent: true)

    await e.beginInstall(holdMs: 5_000)
    await e.track("example_purchase")
    await e.setConsent(false)
    await e.trackInstall(adservicesToken: nil)
    await e.flush()

    let requests = await transport.requests
    XCTAssertEqual(requests, [["ev-1"]])
  }

  /// An installation that already sent its install has nothing to wait for.
  func testNoHoldOnceTheInstallWasSent() async {
    let store = MemoryStore()
    store.preload(INSTALL_SENT_KEY, "1")
    let clock = MutableClock()
    clock.ms = 1_000_000
    let transport = ScriptedTransport([])
    let e = engine(store, clock, transport: transport)

    await e.beginInstall(holdMs: 5_000)
    await e.track("example_purchase")
    await e.flush()

    let requests = await transport.requests
    XCTAssertEqual(requests, [["ev-1"]])
  }
}

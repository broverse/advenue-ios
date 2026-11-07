import Foundation
import XCTest

@testable import AdvenueCore

/// Four behaviours the React Native SDK has always had and the native one did
/// not. They were found by inventorying what the inversion would drop, which is
/// the only reason they are here rather than in a bug report six months from
/// now.
final class ConsentGateTests: XCTestCase {
  private func engine(
    _ store: MemoryStore, requireConsent: Bool = true, transport: (any EventTransport)? = nil
  ) -> AdvenueEngine {
    AdvenueEngine(
      config: EngineConfig(
        apiKey: "apk_test", platform: "ios", deviceId: "d1",
        requireConsent: requireConsent),
      store: store, clock: FixedClock(ms: 0),
      scheduler: RecordingScheduler(), uuid: SequentialUUIDs(prefix: "ev"),
      transport: transport)
  }

  /// The most serious of the four. An app using `requireConsent` that gets
  /// consent after launch would otherwise never send an install at all — no
  /// install, no attribution, for the life of that installation.
  func testAnInstallRefusedForConsentIsSentWhenConsentArrives() async {
    let store = MemoryStore()
    let e = engine(store)

    let refused = await e.trackInstall(adservicesToken: "tok")
    XCTAssertFalse(refused)
    var pending = await e.pendingEvents()
    XCTAssertTrue(pending.isEmpty)

    await e.setConsent(true)

    pending = await e.pendingEvents()
    XCTAssertEqual(pending.filter { $0.type == "install" }.count, 1)
    XCTAssertEqual(
      pending.first(where: { $0.type == "install" })?.adservicesToken, "tok",
      "the enrichment gathered before consent must not be thrown away")
  }

  /// Denying consent is not a deferral: nothing should be waiting to fire.
  func testDenyingConsentDoesNotReleaseTheInstall() async {
    let e = engine(MemoryStore())
    _ = await e.trackInstall(adservicesToken: nil)
    await e.setConsent(false)
    let pending = await e.pendingEvents()
    XCTAssertTrue(pending.isEmpty)
  }

  /// F6: a withdrawal drops the identified events already buffered, including
  /// the blob a debounced persist already wrote, and nothing is uploaded.
  func testWithdrawalDropsThePersistedQueueAndBlocksUpload() async {
    let store = MemoryStore()
    let scheduler = RecordingScheduler()
    let transport = ScriptedTransport([])
    let e = AdvenueEngine(
      config: EngineConfig(apiKey: "apk_test", platform: "ios", deviceId: "d1", requireConsent: true),
      store: store, clock: FixedClock(ms: 0), scheduler: scheduler,
      uuid: SequentialUUIDs(prefix: "ev"), transport: transport)

    await e.setConsent(true)
    await e.track("a")
    await e.track("b")
    scheduler.runAll()
    XCTAssertNotNil(store.raw(QUEUE_KEY), "precondition: the queue blob was persisted")

    await e.setConsent(false)
    await e.flush()

    XCTAssertNil(store.raw(QUEUE_KEY), "the persisted queue must go with the withdrawal")
    let pending = await e.pendingEvents()
    XCTAssertTrue(pending.isEmpty)
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  /// Without requireConsent a denial is a flag on the events, not a gate: the
  /// queue is left alone and keeps uploading.
  func testWithoutRequireConsentADenialKeepsTheQueue() async {
    let store = MemoryStore()
    let transport = ScriptedTransport([])
    let e = AdvenueEngine(
      config: EngineConfig(apiKey: "apk_test", platform: "ios", deviceId: "d1"),
      store: store, clock: FixedClock(ms: 0), scheduler: RecordingScheduler(),
      uuid: SequentialUUIDs(prefix: "ev"), transport: transport)
    await e.track("a")
    await e.setConsent(false)
    await e.flush()
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
  }

  /// Apple's conversion value is a measurement like any other, so it is gated
  /// like any other. Reporting revenue for a user who has not consented is a
  /// compliance failure rather than a parity detail.
  func testSkanIsNotFedWhileConsentIsWithheld() async throws {
    let store = MemoryStore()
    let e = engine(store)
    let reporter = CountingSkanReporter()
    await e.enableSkan(
      mapper: try ConversionValueMapper(
        ConversionValueConfig(rules: [ConversionValueRule(fineValue: 10, events: ["signup"])])),
      currency: nil, installationId: "inst-1", reporter: reporter)

    await e.recordSkan(event: "signup")
    var count = await reporter.updates
    XCTAssertEqual(count, 0, "no conversion value may be reported without consent")

    await e.setConsent(true)
    await e.recordSkan(event: "signup")
    count = await reporter.updates
    XCTAssertEqual(count, 1)
  }

  /// A conversion rule may name "session", and the RN SDK has always fed it.
  func testAForegroundFeedsSkanASessionEvent() async throws {
    let store = MemoryStore()
    let e = engine(store, requireConsent: false)
    let reporter = CountingSkanReporter()
    await e.enableSkan(
      mapper: try ConversionValueMapper(
        ConversionValueConfig(rules: [ConversionValueRule(fineValue: 20, events: ["session"])])),
      currency: nil, installationId: "inst-1", reporter: reporter)

    await e.notifyForeground()

    // The SKAN feed is dispatched, so give it a moment rather than asserting
    // synchronously on an ordering the engine does not promise.
    try await Task.sleep(nanoseconds: 200_000_000)
    let fine = await reporter.lastFine
    XCTAssertEqual(fine, 20, "a session never reached SKAN")
  }
}

actor CountingSkanReporter: SkanReporter {
  private(set) var updates = 0
  private(set) var lastFine: Int?

  nonisolated func register() {}

  func update(fine: Int, coarse: CoarseValue, lockWindow: Bool) async throws {
    updates += 1
    lastFine = fine
  }
}

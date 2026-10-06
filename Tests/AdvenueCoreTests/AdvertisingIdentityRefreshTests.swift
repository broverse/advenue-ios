import Foundation
import XCTest

@testable import AdvenueCore

/// The narrow identity refresh: what a resolved ATT prompt — or a flush /
/// foreground tick — hands the core. It must move the advertising fields and
/// nothing else — the App Instance ID belongs to Firebase, not to the prompt.
final class AdvertisingIdentityRefreshTests: XCTestCase {
  private func engine(_ store: MemoryStore = MemoryStore()) -> AdvenueEngine {
    AdvenueEngine(
      config: EngineConfig(apiKey: "apk_test", platform: "ios", deviceId: "d1"),
      store: store, clock: MutableClock(), scheduler: RecordingScheduler(),
      uuid: SequentialUUIDs(prefix: "ev"))
  }

  func testRefreshStampsSubsequentEvents() async {
    let e = engine()
    await e.setAdvertisingIdentity(idfa: "IDFA-new", vendorId: "VID-new", limitAdTracking: false)
    await e.track("probe")

    let event = await e.pendingEvents().first
    XCTAssertEqual(event?.idfa, "IDFA-new")
    XCTAssertEqual(event?.vendorId, "VID-new")
    XCTAssertEqual(event?.limitAdTracking, false)
  }

  func testRefreshPreservesAppInstanceId() async {
    let e = engine()
    await e.setIdentity(
      idfa: "IDFA-old", vendorId: "VID-old", appInstanceId: "APP-1", limitAdTracking: false)
    await e.setAdvertisingIdentity(idfa: "IDFA-new", vendorId: "VID-new", limitAdTracking: false)
    await e.track("probe")

    let event = await e.pendingEvents().first
    XCTAssertEqual(event?.idfa, "IDFA-new", "the refresh must move the IDFA")
    XCTAssertEqual(
      event?.appInstanceId, "APP-1",
      "the refresh must not clear what the install enrichment resolved")
  }

  func testDenialRefreshSetsLimitAdTracking() async {
    let e = engine()
    await e.setAdvertisingIdentity(idfa: nil, vendorId: nil, limitAdTracking: true)
    await e.track("probe")

    let event = await e.pendingEvents().first
    XCTAssertNil(event?.idfa)
    XCTAssertEqual(event?.limitAdTracking, true)
  }

  func testQueuedEventsKeepTheIdentityTheyWereStampedWith() async {
    let e = engine()
    await e.setIdentity(
      idfa: "IDFA-old", vendorId: "VID-old", appInstanceId: nil, limitAdTracking: false)
    await e.track("before")
    await e.setAdvertisingIdentity(idfa: "IDFA-new", vendorId: "VID-new", limitAdTracking: false)
    await e.track("after")

    let events = await e.pendingEvents()
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events.first?.idfa, "IDFA-old", "history is not rewritten")
    XCTAssertEqual(events.last?.idfa, "IDFA-new")
  }
}

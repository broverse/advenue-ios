import Foundation
import XCTest

@testable import AdvenueCore

final class InstallTests: XCTestCase {
  private func engine(_ store: MemoryStore) -> AdvenueEngine {
    AdvenueEngine(
      config: EngineConfig(apiKey: "apk_test", platform: "ios", deviceId: "d1"),
      store: store, clock: FixedClock(ms: 1_700_000_000_000),
      scheduler: RecordingScheduler(), uuid: SequentialUUIDs(prefix: "ev"))
  }

  func testInstallFiresOncePerInstallation() async {
    let store = MemoryStore()
    let e = engine(store)

    let first = await e.trackInstall(adservicesToken: nil)
    let second = await e.trackInstall(adservicesToken: nil)

    XCTAssertTrue(first, "the first install must be recorded")
    XCTAssertFalse(second, "a second install would bill a second CPI")
    let pending = await e.pendingEventIds()
    XCTAssertEqual(pending.count, 1)
  }

  /// The flag is written after the event, not before: a crash in between costs
  /// a duplicate the backend dedups, while a flag written first would lose the
  /// install permanently.
  func testInstallSentFlagIsPersisted() async {
    let store = MemoryStore()
    let e = engine(store)
    _ = await e.trackInstall(adservicesToken: nil)
    XCTAssertEqual(store.raw(INSTALL_SENT_KEY), "1")
  }

  /// Consent gating must bail before the flag is written, or a consent-deferred
  /// install is lost for the lifetime of the installation.
  func testConsentGateLeavesNoSideEffect() async {
    let store = MemoryStore()
    let e = AdvenueEngine(
      config: EngineConfig(
        apiKey: "apk_test", platform: "ios", deviceId: "d1", requireConsent: true),
      store: store, clock: FixedClock(ms: 1_700_000_000_000),
      scheduler: RecordingScheduler(), uuid: SequentialUUIDs(prefix: "ev"))

    let refused = await e.trackInstall(adservicesToken: nil)
    XCTAssertFalse(refused)
    XCTAssertNil(store.raw(INSTALL_SENT_KEY), "a refused install must leave no flag")

    // Granting consent now RELEASES the deferred install rather than merely
    // permitting a later one — an app that never calls trackInstall again
    // would otherwise have no install at all.
    await e.setConsent(true)
    let pending = await e.pendingEvents()
    XCTAssertEqual(pending.filter { $0.type == "install" }.count, 1)
    XCTAssertEqual(store.raw(INSTALL_SENT_KEY), "1")
  }

  func testIdentityFieldsRideEveryEvent() async {
    let store = MemoryStore()
    let e = engine(store)
    await e.setIdentity(idfa: "IDFA-1", vendorId: "VID-1", appInstanceId: "abc")
    await e.track("purchase")

    let events = await e.pendingEvents()
    XCTAssertEqual(events.first?.idfa, "IDFA-1")
    XCTAssertEqual(events.first?.vendorId, "VID-1")
    XCTAssertEqual(events.first?.appInstanceId, "abc")
  }

  /// The React Native facade exposes `setAppInstanceId` as its own call, and
  /// Firebase resolves the id long after the install enrichment has already set
  /// the advertising identity. Routing it through `setIdentity` would clear the
  /// IDFA and the vendor id every time an app called it — attribution inputs
  /// erased by a diagnostics field.
  func testSettingTheAppInstanceIdKeepsTheAdvertisingIdentity() async {
    let store = MemoryStore()
    let e = engine(store)
    await e.setIdentity(idfa: "IDFA-1", vendorId: "VID-1", appInstanceId: nil)
    await e.setAppInstanceId("fb-123")
    await e.track("purchase")

    let events = await e.pendingEvents()
    XCTAssertEqual(events.first?.idfa, "IDFA-1")
    XCTAssertEqual(events.first?.vendorId, "VID-1")
    XCTAssertEqual(events.first?.appInstanceId, "fb-123")
  }

  /// The AdServices token belongs to the install alone: it is an attribution
  /// input, not a per-event property, and repeating it on every event would put
  /// an opaque token in every request for nothing.
  /// B2: rıza bayrağı düşürülmüyor — olaya işlenir.
  func testLimitAdTrackingRidesEveryEvent() async {
    let store = MemoryStore()
    let e = engine(store)
    await e.setIdentity(
      idfa: "IDFA-1", vendorId: "VID-1", appInstanceId: nil, limitAdTracking: true)
    await e.track("purchase")

    let events = await e.pendingEvents()
    XCTAssertEqual(events.first?.limitAdTracking, true)
  }

  func testLimitAdTrackingAbsentStaysAbsent() async {
    let store = MemoryStore()
    let e = engine(store)
    await e.setIdentity(idfa: "IDFA-1", vendorId: "VID-1", appInstanceId: nil)
    await e.track("purchase")

    let events = await e.pendingEvents()
    XCTAssertNil(events.first?.limitAdTracking)
  }

  func testAdservicesTokenRidesOnlyTheInstall() async {
    let store = MemoryStore()
    let e = engine(store)
    _ = await e.trackInstall(adservicesToken: "tok-1")
    await e.track("purchase")

    let events = await e.pendingEvents()
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events[0].adservicesToken, "tok-1")
    XCTAssertEqual(events[0].type, "install")
    XCTAssertNil(events[1].adservicesToken)
  }
}

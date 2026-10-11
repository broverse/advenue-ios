import Foundation
import XCTest

@testable import AdvenueCore

/// `attStatus` and `installationId` on every event (outbound privacy layer,
/// Task 15). The server decides what a postback may share from the ATT state
/// the event was sent under, so an event without it falls back to a guess.
final class AttStatusTests: XCTestCase {
  private func engine(
    attStatus: String? = nil, installationId: String? = nil
  ) -> AdvenueEngine {
    AdvenueEngine(
      config: EngineConfig(
        apiKey: "apk_test", platform: "ios", deviceId: "d1",
        installationId: installationId, attStatus: attStatus),
      store: MemoryStore(), clock: MutableClock(), scheduler: RecordingScheduler(),
      uuid: SequentialUUIDs(prefix: "ev"))
  }

  /// Seeded at initialize, so an event tracked before the first refresh or the
  /// install enrichment still says what ATT was.
  func testTheInitialStatusStampsTheFirstEvent() async {
    let e = engine(attStatus: "not_determined")
    await e.track("probe")

    let event = await e.pendingEvents().first
    XCTAssertEqual(event?.attStatus, "not_determined")
  }

  func testARefreshMovesTheStatus() async {
    let e = engine(attStatus: "not_determined")
    await e.setAdvertisingIdentity(
      idfa: nil, vendorId: nil, limitAdTracking: true, attStatus: "denied")
    await e.track("probe")

    let event = await e.pendingEvents().first
    XCTAssertEqual(event?.attStatus, "denied")
  }

  /// nil means "not read", never "no status": a caller that does not know the
  /// status must not erase the one the engine has.
  func testARefreshWithoutAStatusKeepsTheLastOne() async {
    let e = engine(attStatus: "authorized")
    await e.setAdvertisingIdentity(idfa: "IDFA-1", vendorId: nil, limitAdTracking: false)
    await e.track("probe")

    let event = await e.pendingEvents().first
    XCTAssertEqual(event?.attStatus, "authorized")
  }

  /// The install's IDFA is read after the ATT wait; its status must be the
  /// one read alongside it, or an install ships an IDFA under "not_determined".
  func testTheInstallCarriesTheStatusEnrichmentRead() async {
    let e = engine(attStatus: "not_determined")
    await e.setIdentity(
      idfa: "IDFA-1", vendorId: "VID-1", appInstanceId: nil, limitAdTracking: false,
      attStatus: "authorized")
    await e.trackInstall(adservicesToken: nil)

    let install = await e.pendingEvents().first { $0.type == "install" }
    XCTAssertEqual(install?.attStatus, "authorized")
    XCTAssertEqual(install?.idfa, "IDFA-1")
  }

  func testSessionEventsCarryIt() async {
    let e = engine(attStatus: "restricted")
    await e.notifyForeground()

    let session = await e.pendingEvents().first { $0.type == "session" }
    XCTAssertNotNil(session, "a foreground must open a session")
    XCTAssertEqual(session?.attStatus, "restricted")
  }

  /// A queued event is re-encoded from its persisted form after a relaunch;
  /// a decoder that skips the key sends the reloaded batch without it.
  func testTheStatusSurvivesTheQueueRoundTrip() throws {
    var event = ClientEvent(
      id: "i", deviceId: "d", type: "custom", name: "e",
      timestamp: EventEncoding.iso8601(ms: 0), platform: "ios")
    event.attStatus = "denied"

    let json = try event.encodeCanonical()
    XCTAssertTrue(json.contains(#""attStatus":"denied""#), json)
    let decoded = try JSONDecoder().decode(ClientEvent.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.attStatus, "denied")
  }

  func testAnUnknownStatusIsOmittedNotNull() throws {
    let event = ClientEvent(
      id: "i", deviceId: "d", type: "custom", name: "e",
      timestamp: EventEncoding.iso8601(ms: 0), platform: "ios")
    let json = try event.encodeCanonical()
    XCTAssertFalse(json.contains("attStatus"), "zod .optional() rejects null")
  }

  /// The server keys per-install postback identity on it (P-13), so every
  /// event type must carry it — custom, session and install.
  func testEveryEventTypeCarriesTheInstallationId() async {
    let e = engine(installationId: "00000000-0000-4000-8000-000000000009")
    await e.notifyForeground()
    await e.track("probe")
    await e.trackInstall(adservicesToken: nil)

    let events = await e.pendingEvents()
    XCTAssertEqual(Set(events.map(\.type)), ["session", "custom", "install"])
    for event in events {
      XCTAssertEqual(
        event.installationId, "00000000-0000-4000-8000-000000000009",
        "\(event.type) event shipped without the installation id")
    }
  }
}

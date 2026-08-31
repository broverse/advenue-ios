import Foundation
import XCTest

@testable import Advenue
@testable import AdvenueCore
@testable import AdvenuePlatform

/// Records every batch it is handed.
actor RecordingTransport: EventTransport {
  private(set) var seen: [[String]] = []
  func send(_ events: [ClientEvent]) async throws { seen.append(events.map(\.name)) }
}

/// Keeps whole events, not just names, so a seam test can assert the fields a
/// capability contributes.
actor RecordingEventTransport: EventTransport {
  private(set) var events: [ClientEvent] = []
  func send(_ batch: [ClientEvent]) async throws { events.append(contentsOf: batch) }
  func installEvent() -> ClientEvent? { events.first { $0.type == "install" } }
}

/// The test the component suites could not fail.
///
/// Every piece of the send path had its own passing test — `HttpTransport.send`,
/// `IngestError.isRetryable`, `backoffDelayMs`, `EventQueue.ack` — while nothing
/// in `Sources/` ever referenced `HttpTransport`. The SDK queued events into
/// UserDefaults and transmitted none of them, and 78 green tests reported it as
/// working. Unit coverage of every component says nothing about the seams
/// between them, so this asserts the seam directly: an event handed to the
/// public facade reaches a transport.
final class SeamTests: XCTestCase {
  /// The install is once per installation, and the host test process shares one
  /// real UserDefaults suite across runs — so the first run writes the flag and
  /// every later run correctly refuses to fire a second install. That is the
  /// guard working, not a bug, but it makes the assertion depend on whether
  /// this machine has run the suite before. Clearing the flag makes the test
  /// assert the wiring rather than the history of the developer's laptop.
  override func setUp() {
    super.setUp()
    UserDefaults(suiteName: ADVENUE_SUITE)?.removeObject(forKey: INSTALL_SENT_KEY)
  }

  override func tearDown() {
    Advenue.shutdown()
    super.tearDown()
  }

  func testTrackedEventReachesTheTransport() async throws {
    let transport = RecordingTransport()
    let state = FacadeState()
    state.start(AdvenueConfig(apiKey: "apk_live_x"), transport: transport)

    // The invariant under test is the wiring, not the Keychain: an unsigned
    // simulator bundle cannot read it, and asserting an environment would make
    // this a test of the runner.
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.submit(.track(name: "purchase", properties: nil, type: "custom"))
    state.submit(.flush)

    try await Self.until(timeout: 3) { await !transport.seen.isEmpty }
    let seen = await transport.seen
    XCTAssertTrue(
      seen.flatMap { $0 }.contains("purchase"),
      "an event given to the facade never reached a transport")
  }

  /// The second seam. `SearchAdsTokenFetcher` had zero references in `Sources/`,
  /// `appInstanceIdProvider` was stored and never read, and no install event
  /// existed at all — every one of them individually tested. This asserts that
  /// an install reaches a transport carrying what the collector gathered.
  func testInstallReachesTheTransportEnriched() async throws {
    let transport = RecordingEventTransport()
    let state = FacadeState()
    let sources = EnrichmentSources(
      searchAdsToken: { "tok-seam" },
      advertisingId: { (idfa: "IDFA-seam", vendorId: "VID-seam") },
      appInstanceId: { "aaaaaaaabbbbbbbbccccccccdddddddd" })

    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(config, transport: transport, sources: sources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    try await Self.until(timeout: 5) { await transport.installEvent() != nil }
    let install = await transport.installEvent()

    XCTAssertEqual(install?.adservicesToken, "tok-seam", "the Search Ads token never shipped")
    XCTAssertEqual(install?.idfa, "IDFA-seam", "the IDFA never shipped")
    XCTAssertEqual(install?.appInstanceId, "aaaaaaaabbbbbbbbccccccccdddddddd")
  }

  /// Polls rather than sleeping a fixed interval: the pipe is asynchronous, and
  /// a fixed sleep is either flaky or slow.
  private static func until(
    timeout: TimeInterval, _ condition: @Sendable () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("condition never became true within \(timeout)s")
  }
}

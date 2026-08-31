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

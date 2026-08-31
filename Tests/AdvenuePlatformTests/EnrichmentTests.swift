import Foundation
import XCTest

@testable import AdvenuePlatform

final class EnrichmentTests: XCTestCase {
  /// The deadline is the point. A source that never answers must cost the
  /// install its field, not its timeliness: holding the install shifts every
  /// attribution window behind it.
  func testASlowSourceDoesNotHoldTheInstall() async {
    let sources = EnrichmentSources(
      searchAdsToken: {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        return "never-arrives"
      },
      advertisingId: { (idfa: "IDFA-1", vendorId: "VID-1") },
      appInstanceId: { "abc" })

    let started = Date()
    let result = await collectEnrichment(sources, deadlineMs: 300)

    XCTAssertLessThan(
      Date().timeIntervalSince(started), 3.0, "the deadline did not bound the wait")
    XCTAssertNil(result.adservicesToken, "a source past the deadline contributes nothing")
    XCTAssertEqual(result.idfa, "IDFA-1", "ready sources must still be collected")
    XCTAssertEqual(result.vendorId, "VID-1")
  }

  func testEverythingReadyIsCollected() async {
    let sources = EnrichmentSources(
      searchAdsToken: { "tok-1" },
      advertisingId: { (idfa: "IDFA-1", vendorId: "VID-1") },
      appInstanceId: { "abc" })

    let result = await collectEnrichment(sources, deadlineMs: 3_000)

    XCTAssertEqual(result.adservicesToken, "tok-1")
    XCTAssertEqual(result.idfa, "IDFA-1")
    XCTAssertEqual(result.appInstanceId, "abc")
  }

  /// Absent sources are the common case — no Firebase, no Search Ads, ATT not
  /// determined — and must produce an install, not a failure.
  func testAllSourcesAbsentStillProducesAnEnrichment() async {
    let sources = EnrichmentSources(
      searchAdsToken: { nil },
      advertisingId: { (idfa: nil, vendorId: nil) },
      appInstanceId: { nil })

    let result = await collectEnrichment(sources, deadlineMs: 3_000)

    XCTAssertNil(result.adservicesToken)
    XCTAssertNil(result.idfa)
    XCTAssertNil(result.appInstanceId)
  }
}

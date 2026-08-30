import Foundation
import XCTest

@testable import AdvenueCore

final class EnvelopeVectorTests: XCTestCase {
  func testTimestampMatchesToISOString() {
    // The two values the TypeScript snapshots pinned.
    XCTAssertEqual(EventEncoding.iso8601(ms: 1_767_225_600_000), "2026-01-01T00:00:00.000Z")
    XCTAssertEqual(EventEncoding.iso8601(ms: 0), "1970-01-01T00:00:00.000Z")
    // Three digits even when the millisecond field is small — a %d here would
    // emit "…:00.7Z" and every timestamp on the wire would be wrong.
    XCTAssertEqual(EventEncoding.iso8601(ms: 7), "1970-01-01T00:00:00.007Z")
    XCTAssertEqual(EventEncoding.iso8601(ms: 1_767_225_600_123), "2026-01-01T00:00:00.123Z")
  }

  func testAbsentOptionalsAreOmittedNotNull() throws {
    var event = ClientEvent(
      id: "event-uuid-1", deviceId: "dev-2", type: "custom", name: "e",
      timestamp: EventEncoding.iso8601(ms: 0), platform: "android")
    event.installationId = "00000000-0000-4000-8000-000000000002"

    let json = try event.encodeCanonical()
    XCTAssertFalse(json.contains("null"), "zod .optional() rejects null: \(json)")
    XCTAssertEqual(
      json,
      #"{"deviceId":"dev-2","id":"event-uuid-1","installationId":"00000000-0000-4000-8000-000000000002","name":"e","platform":"android","timestamp":"1970-01-01T00:00:00.000Z","type":"custom"}"#
    )
  }

  func testPropertiesEncodeAsJSON() throws {
    var event = ClientEvent(
      id: "i", deviceId: "d", type: "custom", name: "purchase",
      timestamp: EventEncoding.iso8601(ms: 0), platform: "ios")
    event.properties = ["price": 9.99, "tier": "gold", "first": true]

    let json = try event.encodeCanonical()
    XCTAssertTrue(json.contains(#""properties":{"first":true,"price":9.99,"tier":"gold"}"#), json)
  }

  /// Guards the pairing the envelope vectors exist to protect: every vector
  /// file has a matching expectation here, so adding a vector without teaching
  /// Swift about it fails rather than passing silently.
  func testEveryEnvelopeVectorIsAccountedFor() throws {
    let files = try loadVectors("envelope").map(\.file).sorted()
    XCTAssertEqual(
      files,
      [
        "absent-fields-omitted.json",
        "install-with-identifiers.json",
        "minimal-custom.json",
        "push-token-lifecycle-only.json",
      ])
  }
}

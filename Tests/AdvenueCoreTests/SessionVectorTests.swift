import Foundation
import XCTest

@testable import AdvenueCore

final class SessionVectorTests: XCTestCase {
  func testSessionVectors() throws {
    let vectors = try loadVectors("session")
    XCTAssertFalse(vectors.isEmpty, "session vectors must be bundled")

    for vector in vectors {
      let clock = MutableClock()
      let tracker = SessionTracker(
        store: MemoryStore(), clock: clock,
        windowMs: Int64(try vector.value("windowMs") as Int),
        uuid: SequentialUUIDs(prefix: "sid"))

      let steps: [[String: Any]] = try vector.value("steps")
      for (index, step) in steps.enumerated() {
        clock.ms = Int64(step["at"] as! Int)
        let emitted: [SessionEvent] =
          (step["op"] as! String) == "foreground"
          ? tracker.handleForeground()
          : [tracker.handleBackground()].compactMap { $0 }

        let expected = step["expect"] as! [[String: Any]]
        let context = "\(vector.file) step \(index) at \(step["at"] ?? "?")"
        XCTAssertEqual(emitted.count, expected.count, "\(context): event count")
        for (emittedEvent, expectedEvent) in zip(emitted, expected) {
          XCTAssertEqual(emittedEvent.name, expectedEvent["name"] as! String, context)
          XCTAssertEqual(
            try Self.canonical(emittedEvent.properties),
            try Self.canonical(expectedEvent["properties"] as! [String: Any]),
            "\(context): properties of \(emittedEvent.name)")
        }
      }
    }
  }

  /// Both sides are compared as canonical JSON text rather than as
  /// reconstructed Swift values.
  ///
  /// Rebuilding the expectation with `case let v as Bool` / `as Int` looks
  /// obvious and is wrong: `JSONSerialization` yields `NSNumber`, which bridges
  /// to Bool AND Int, so `sessionNumber: 1` silently becomes `.bool(true)` and
  /// `timeSinceLastSessionMs: 0` becomes `.bool(false)`. In JSON text the two
  /// are unambiguous, and the comparison is portable to Linux where the
  /// NSNumber bridging rules differ again.
  private static func canonical(_ properties: [String: AdvenueValue]) throws -> String {
    let data = try EventEncoding.canonicalEncoder().encode(properties)
    return String(decoding: data, as: UTF8.self)
  }

  private static func canonical(_ raw: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
}

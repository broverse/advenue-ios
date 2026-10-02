import Foundation
import XCTest

@testable import AdvenueCore

final class SessionVectorTests: XCTestCase {
  func testSessionVectors() throws {
    let vectors = try loadVectors("session")
    XCTAssertFalse(vectors.isEmpty, "session vectors must be bundled")

    for vector in vectors {
      let clock = MutableClock()
      // One store and one UUID source for the whole vector: `relaunch` is a
      // new process — a fresh tracker over the state the old one persisted.
      let store = MemoryStore()
      let uuids = SequentialUUIDs(prefix: "sid")
      let windowMs = Int64(try vector.value("windowMs") as Int)
      var tracker = SessionTracker(store: store, clock: clock, windowMs: windowMs, uuid: uuids)

      let steps: [[String: Any]] = try vector.value("steps")
      for (index, step) in steps.enumerated() {
        clock.ms = Int64(step["at"] as! Int)
        let emitted: [SessionEvent]
        switch step["op"] as! String {
        case "foreground": emitted = tracker.handleForeground()
        case "background": emitted = [tracker.handleBackground()].compactMap { $0 }
        case "heartbeat":
          tracker.heartbeat()
          emitted = []
        case "relaunch":
          tracker = SessionTracker(store: store, clock: clock, windowMs: windowMs, uuid: uuids)
          emitted = []
        case let op: XCTFail("\(vector.file): unknown op \(op)"); emitted = []
        }

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

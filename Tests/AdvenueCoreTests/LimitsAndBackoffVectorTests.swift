import Foundation
import XCTest

@testable import AdvenueCore

final class LimitsAndBackoffVectorTests: XCTestCase {
  /// Properties whose canonical JSON length is exactly `bytes`.
  /// `{"p":""}` is 8 characters of scaffolding around the padding.
  private func properties(ofSize bytes: Int) -> [String: AdvenueValue] {
    ["p": .string(String(repeating: "x", count: bytes - 8))]
  }

  func testPropertiesSizeHelperIsExact() throws {
    // The guard is an inclusive bound, so an off-by-one here would silently
    // turn the boundary vector into a different test.
    let data = try EventEncoding.canonicalEncoder().encode(properties(ofSize: 8192))
    XCTAssertEqual(data.count, 8192)
  }

  func testLimitsVectors() throws {
    let vectors = try loadVectors("limits")
    XCTAssertFalse(vectors.isEmpty, "limits vectors must be bundled")

    for vector in vectors {
      let input: [String: Any] = try vector.value("input")
      let expected: [String: Any] = try vector.value("expected")

      let name =
        (input["name"] as? String)
        ?? String(repeating: "e", count: input["nameLength"] as? Int ?? 1)
      let props = (input["propertiesBytes"] as? Int).map(properties(ofSize:))

      let rejection = checkTrackInput(name: name, properties: props)
      let accepted = expected["accepted"] as! Bool

      XCTAssertEqual(rejection == nil, accepted, "\(vector.file): \(vector.name)")
      if let reason = expected["reason"] as? String {
        XCTAssertEqual(rejection?.rawValue, reason, vector.file)
      }
    }
  }

  func testBackoffVectors() throws {
    let vectors = try loadVectors("backoff")
    XCTAssertFalse(vectors.isEmpty, "backoff vectors must be bundled")

    for vector in vectors {
      if let cases = vector.optional("cases", as: [[String: Any]].self) {
        for entry in cases {
          let status = entry["status"] as! Int
          XCTAssertEqual(
            IngestError(status: status).isRetryable,
            entry["retryable"] as! Bool,
            "\(vector.file) status \(status)")
        }
      }
      if let schedule = vector.optional("schedule", as: [String: Any].self) {
        let base = Double(schedule["baseMs"] as! Int)
        let cap = Double(schedule["capMs"] as! Int)
        let failures = schedule["failures"] as! [Int]
        let none = (schedule["expectedNoJitterMs"] as! [Int]).map(Double.init)
        let full = (schedule["expectedFullJitterMs"] as! [Int]).map(Double.init)

        XCTAssertEqual(
          failures.map { backoffDelayMs(failures: $0, baseMs: base, capMs: cap, random: 0) },
          none, vector.file)
        XCTAssertEqual(
          failures.map { backoffDelayMs(failures: $0, baseMs: base, capMs: cap, random: 1) },
          full, vector.file)
      }
    }
  }
}

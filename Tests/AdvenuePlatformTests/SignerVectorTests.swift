import Foundation
import XCTest

@testable import AdvenueCore
@testable import AdvenuePlatform

/// The production signer runs the same vectors the core's swift-crypto signer
/// runs, against the same expected hex the TypeScript runner recorded.
///
/// This is what the design audit said a compile-time `#if canImport` branch
/// could not establish: with the branch, Linux tests only the fallback and
/// macOS only CryptoKit, and no run ever compares them. Pointing all three
/// implementations at one set of expected bytes makes their agreement
/// transitive through the vector.
final class SignerVectorTests: XCTestCase {
  static let expected: [String: String] = [
    "basic.json": "9ab0cd868afcea3460021dbe2b1c7f2d964be29a25e14b416aa5f8eb3c9899ef",
    "empty-body.json": "e4bd0dfa59a710d6c6cc505ef0b1756970fc63fa9c82f0998bfdf4b9ff0c6cd7",
    "unicode-body.json": "66c12ad1eacaa5033f218245c18f1419472f359a2cef4d139ba2b8fb4b17dbbd",
  ]

  func testCryptoKitSignerMatchesTheVectors() throws {
    let signer = CryptoKitSigner()
    guard let root = Bundle.module.url(forResource: "vectors", withExtension: nil) else {
      return XCTFail("vectors not bundled — run `pnpm conformance:sync`")
    }
    let dir = root.appendingPathComponent("signing")
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter { $0.hasSuffix(".json") }.sorted()
    XCTAssertEqual(files.count, Self.expected.count, "a new vector needs an expected value here")

    for file in files {
      let data = try Data(contentsOf: dir.appendingPathComponent(file))
      let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
      let input = body["input"] as! [String: Any]
      let signature = signRequest(
        signer,
        secret: input["secret"] as! String,
        timestamp: input["timestamp"] as! String,
        body: input["body"] as! String)
      XCTAssertEqual(signature, Self.expected[file], file)
    }
  }

  func testSchedulerRunsAndCancels() {
    let scheduler = TimerScheduler()
    let ran = XCTestExpectation(description: "scheduled work runs")
    _ = scheduler.schedule(afterMs: 1) { ran.fulfill() }
    wait(for: [ran], timeout: 2)

    let cancelled = XCTestExpectation(description: "cancelled work does not run")
    cancelled.isInverted = true
    let token = scheduler.schedule(afterMs: 50) { cancelled.fulfill() }
    scheduler.cancel(token)
    wait(for: [cancelled], timeout: 0.3)
  }

  func testSystemClockIsInMilliseconds() {
    let now = SystemClock().nowMs()
    // Sanity: milliseconds since 1970 is a 13-digit number in this era. A
    // seconds-based clock would silently shift every event timestamp by three
    // orders of magnitude.
    XCTAssertGreaterThan(now, 1_700_000_000_000)
    XCTAssertLessThan(now, 4_000_000_000_000)
  }
}

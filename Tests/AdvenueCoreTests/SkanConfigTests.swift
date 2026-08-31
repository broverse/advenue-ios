import Foundation
import XCTest

@testable import AdvenueCore

final class SkanConfigTests: XCTestCase {
  private let good = ConversionValueConfig(rules: [ConversionValueRule(fineValue: 10)])
  private let bad = ConversionValueConfig(rules: [ConversionValueRule(fineValue: 99)])

  func testAFetchedConfigWins() {
    let remote = RemoteSkanConfig(version: 7, rules: good)
    let chosen = chooseSkanConfig(fetched: .fetched(remote), cached: nil, fallback: nil)
    XCTAssertEqual(chosen?.version, 7)
  }

  /// A device on a flaky network must not lose SKAN entirely. A config from
  /// last week measures far more than no config at all.
  func testAFailedFetchKeepsTheCachedConfig() {
    let cached = RemoteSkanConfig(version: 3, rules: good)
    XCTAssertEqual(chooseSkanConfig(fetched: nil, cached: cached, fallback: nil)?.version, 3)
    XCTAssertEqual(
      chooseSkanConfig(fetched: .notModified, cached: cached, fallback: nil)?.version, 3)
  }

  /// The failure a remote config exists to avoid, not to create: a bad config
  /// pushed to production would otherwise brick measurement on every device at
  /// once.
  func testAnInvalidFetchedConfigIsRefusedAndTheCacheKept() {
    let cached = RemoteSkanConfig(version: 3, rules: good)
    let chosen = chooseSkanConfig(
      fetched: .fetched(RemoteSkanConfig(version: 9, rules: bad)),
      cached: cached, fallback: nil)
    XCTAssertEqual(chosen?.version, 3, "the invalid version 9 must not be adopted")
  }

  /// The app-supplied config is an offline default, which is why it stays in
  /// AdvenueConfig rather than being removed once the server can serve one.
  func testTheAppSuppliedConfigIsTheLastResort() {
    let chosen = chooseSkanConfig(fetched: nil, cached: nil, fallback: good)
    XCTAssertEqual(chosen?.rules, good)
    XCTAssertEqual(chosen?.version, 0, "version 0 marks 'not from the server'")
  }

  func testNoConfigAnywhereMeansSkanIsNotArmed() {
    XCTAssertNil(chooseSkanConfig(fetched: nil, cached: nil, fallback: nil))
    XCTAssertNil(chooseSkanConfig(fetched: nil, cached: nil, fallback: bad))
  }
}

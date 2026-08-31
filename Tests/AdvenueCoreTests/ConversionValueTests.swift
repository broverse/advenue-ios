import Foundation
import XCTest

@testable import AdvenueCore

final class ConversionValueTests: XCTestCase {
  /// Apple's even thirds of the 0–63 range. The boundaries are the whole test:
  /// an off-by-one silently reassigns a third of every advertiser's postbacks to
  /// the wrong coarse bucket, and nothing downstream can detect it.
  func testCoarseBoundaries() {
    XCTAssertEqual(deriveCoarse(0), .low)
    XCTAssertEqual(deriveCoarse(21), .low)
    XCTAssertEqual(deriveCoarse(22), .medium)
    XCTAssertEqual(deriveCoarse(42), .medium)
    XCTAssertEqual(deriveCoarse(43), .high)
    XCTAssertEqual(deriveCoarse(63), .high)
  }

  /// The highest matching rule wins, not the first or the last. Rule order in a
  /// config is an authoring convenience and must not change the outcome.
  func testTheHighestMatchingRuleWins() throws {
    let mapper = try ConversionValueMapper(
      ConversionValueConfig(rules: [
        ConversionValueRule(fineValue: 40, events: ["signup"]),
        ConversionValueRule(fineValue: 10, events: ["signup"]),
        ConversionValueRule(fineValue: 25, events: ["signup"]),
      ]))

    let result = mapper.compute(MeasurementState(events: ["signup"]))
    XCTAssertEqual(result.fineValue, 40)
    XCTAssertEqual(result.coarseValue, .medium)
  }

  func testNoMatchYieldsZeroAndTheDefaultCoarse() throws {
    let mapper = try ConversionValueMapper(
      ConversionValueConfig(
        rules: [ConversionValueRule(fineValue: 30, events: ["purchase"])],
        defaultCoarse: .medium))

    let result = mapper.compute(MeasurementState(events: ["signup"]))
    XCTAssertEqual(result.fineValue, 0)
    XCTAssertEqual(result.coarseValue, .medium, "the configured default, not a derived one")
  }

  func testAnExplicitCoarseOverridesTheDerivedOne() throws {
    let mapper = try ConversionValueMapper(
      ConversionValueConfig(rules: [
        ConversionValueRule(fineValue: 5, coarseValue: .high, events: ["whale"])
      ]))
    XCTAssertEqual(mapper.compute(MeasurementState(events: ["whale"])).coarseValue, .high)
  }

  /// Every named event must have been seen, not just one of them.
  func testAllRequiredEventsMustBePresent() throws {
    let mapper = try ConversionValueMapper(
      ConversionValueConfig(rules: [
        ConversionValueRule(fineValue: 20, events: ["signup", "purchase"])
      ]))
    XCTAssertEqual(mapper.compute(MeasurementState(events: ["signup"])).fineValue, 0)
    XCTAssertEqual(
      mapper.compute(MeasurementState(events: ["signup", "purchase"])).fineValue, 20)
  }

  /// Money is compared exactly. A Double cannot distinguish these two values,
  /// and treating them as equal silently misprices a conversion.
  func testRevenueIsComparedExactlyAtLargeMagnitudes() throws {
    let mapper = try ConversionValueMapper(
      ConversionValueConfig(
        rules: [ConversionValueRule(fineValue: 60, minRevenueMicros: "9007199254740993")],
        revenueCurrency: "USD"))

    let justUnder = MeasurementState(
      revenueMicros: "9007199254740992", revenueCurrency: "USD")
    let exactly = MeasurementState(
      revenueMicros: "9007199254740993", revenueCurrency: "USD")

    XCTAssertEqual(mapper.compute(justUnder).fineValue, 0)
    XCTAssertEqual(mapper.compute(exactly).fineValue, 60, "the threshold is inclusive")
  }

  func testMicrosCompareByMagnitudeNotLexicographically() {
    XCTAssertTrue(microsLess("9", "10"), "9 < 10 despite '9' > '1'")
    XCTAssertFalse(microsLess("100", "99"))
    XCTAssertFalse(microsLess("5", "5"))
  }

  /// The fix in e2df538. An app that switches SKAN currency mid-window leaves
  /// persisted revenue in the old denomination; that revenue is unusable for
  /// the comparison, so the rule does not match. Throwing froze the device's
  /// conversion value for the rest of the window, because every later
  /// evaluation re-threw into the SDK's fire-and-forget catch.
  func testACurrencyMismatchIsANonMatchNotAThrow() throws {
    let mapper = try ConversionValueMapper(
      ConversionValueConfig(
        rules: [
          ConversionValueRule(fineValue: 50, minRevenueMicros: "1000000"),
          ConversionValueRule(fineValue: 5, events: ["signup"]),
        ],
        revenueCurrency: "USD"))

    let stale = MeasurementState(
      events: ["signup"], revenueMicros: "9999999999", revenueCurrency: "EUR")

    // The revenue rule cannot match, but the event rule still can — the device
    // keeps measuring instead of freezing at whatever it last reported.
    XCTAssertEqual(mapper.compute(stale).fineValue, 5)
  }

  func testMissingRevenueSimplyDoesNotMatchARevenueRule() throws {
    let mapper = try ConversionValueMapper(
      ConversionValueConfig(
        rules: [ConversionValueRule(fineValue: 50, minRevenueMicros: "1")],
        revenueCurrency: "USD"))
    XCTAssertEqual(mapper.compute(MeasurementState()).fineValue, 0)
  }

  /// Rejected at construction, not at compute: a config mistake should surface
  /// when the config is loaded, not silently report fine value 0 from every
  /// device for a week.
  func testAnOutOfRangeFineValueIsRejectedAtConstruction() {
    for bad in [-1, 64, 999] {
      XCTAssertThrowsError(
        try ConversionValueMapper(
          ConversionValueConfig(rules: [ConversionValueRule(fineValue: bad)])),
        "fineValue \(bad) must be refused")
    }
  }

  func testRevenueRulesRequireACurrency() {
    XCTAssertThrowsError(
      try ConversionValueMapper(
        ConversionValueConfig(
          rules: [ConversionValueRule(fineValue: 10, minRevenueMicros: "100")])))
  }

  func testMalformedMicrosAreRejected() {
    for bad in ["", "-1", "1.5", "01", " 1", "1e6"] {
      XCTAssertThrowsError(
        try ConversionValueMapper(
          ConversionValueConfig(
            rules: [ConversionValueRule(fineValue: 10, minRevenueMicros: bad)],
            revenueCurrency: "USD")),
        "micros \"\(bad)\" must be refused")
    }
  }

  /// The React Native bridge hands over the app's price string ("9.99"), not
  /// micros. Converting it in JavaScript would put a money computation back in
  /// the layer this release is emptying, so the conversion lives here — and it
  /// must be exact: `Double("0.07") * 1_000_000` is 69999.999…, which truncates
  /// to a cent less than the user paid.
  func testDecimalAmountsConvertToExactMicros() {
    XCTAssertEqual(decimalToMicros("0"), "0")
    XCTAssertEqual(decimalToMicros("9.99"), "9990000")
    XCTAssertEqual(decimalToMicros("0.07"), "70000")
    XCTAssertEqual(decimalToMicros("0.000001"), "1")
    XCTAssertEqual(decimalToMicros("12"), "12000000")
    // Past 2^53, where a Double stops being able to count.
    XCTAssertEqual(decimalToMicros("9007199254.740993"), "9007199254740993")
  }

  /// A malformed amount is refused rather than coerced. A silently-zeroed
  /// purchase reports a conversion value that never happened.
  func testMalformedAmountsAreRefused() {
    for bad in ["", "-1", "1.2345678", "01", " 1", "1e6", "1.", ".5", "abc"] {
      XCTAssertNil(decimalToMicros(bad), "amount \"\(bad)\" must be refused")
    }
  }

  func testMalformedCurrenciesAreRejected() {
    for bad in ["usd", "US", "USDD", "US1"] {
      XCTAssertThrowsError(
        try ConversionValueMapper(
          ConversionValueConfig(rules: [], revenueCurrency: bad)),
        "currency \"\(bad)\" must be refused")
    }
  }
}

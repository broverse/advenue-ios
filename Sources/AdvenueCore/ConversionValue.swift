import Foundation

/// SKAdNetwork 4's coarse bucket. Apple sends this instead of the fine value
/// when a device's install volume is below its crowd-anonymity threshold, so it
/// is not a fallback — for low-volume campaigns it is the only signal.
public enum CoarseValue: String, Codable, Sendable, CaseIterable {
  case low
  case medium
  case high
}

/// Maps a fine value to its coarse bucket by Apple's even thirds of 0–63.
///
/// The boundaries are the whole function: an off-by-one silently reassigns a
/// third of every advertiser's postbacks to the wrong bucket, and nothing
/// downstream can detect it.
public func deriveCoarse(_ fineValue: Int) -> CoarseValue {
  if fineValue <= 21 { return .low }
  if fineValue <= 42 { return .medium }
  return .high
}

public struct ConversionValueRule: Codable, Equatable, Sendable {
  public var fineValue: Int
  /// Overrides the derived bucket when the advertiser wants a specific one.
  public var coarseValue: CoarseValue?
  /// Canonical non-negative base-10 micros. A string, not a number, because
  /// money must never go through a Double.
  public var minRevenueMicros: String?
  /// Every named event must have been seen for the rule to match.
  public var events: [String]?

  public init(
    fineValue: Int, coarseValue: CoarseValue? = nil,
    minRevenueMicros: String? = nil, events: [String]? = nil
  ) {
    self.fineValue = fineValue
    self.coarseValue = coarseValue
    self.minRevenueMicros = minRevenueMicros
    self.events = events
  }
}

public struct ConversionValueConfig: Codable, Equatable, Sendable {
  public var rules: [ConversionValueRule]
  public var defaultCoarse: CoarseValue?
  /// Three-letter uppercase ISO code. Required when any rule has a revenue
  /// threshold, because comparing two amounts in different denominations is
  /// meaningless.
  public var revenueCurrency: String?

  public init(
    rules: [ConversionValueRule], defaultCoarse: CoarseValue? = nil,
    revenueCurrency: String? = nil
  ) {
    self.rules = rules
    self.defaultCoarse = defaultCoarse
    self.revenueCurrency = revenueCurrency
  }
}

/// What has accumulated on the device for the current measurement window.
public struct MeasurementState: Equatable, Sendable {
  public var events: [String]
  public var revenueMicros: String?
  public var revenueCurrency: String?

  public init(
    events: [String] = [], revenueMicros: String? = nil, revenueCurrency: String? = nil
  ) {
    self.events = events
    self.revenueMicros = revenueMicros
    self.revenueCurrency = revenueCurrency
  }
}

public struct ConversionValue: Equatable, Sendable {
  public let fineValue: Int
  public let coarseValue: CoarseValue
}

public enum ConversionConfigError: Error, Equatable, CustomStringConvertible {
  case fineValueOutOfRange(Int)
  case malformedMicros(String)
  case malformedCurrency(String)
  case revenueRuleWithoutCurrency

  public var description: String {
    switch self {
    case .fineValueOutOfRange(let value):
      return "conversion fineValue must be an integer 0–63, got \(value)"
    case .malformedMicros(let value):
      return "minRevenueMicros must be a canonical non-negative base-10 integer, got \(value)"
    case .malformedCurrency(let value):
      return "revenueCurrency must be a three-letter uppercase ISO currency, got \(value)"
    case .revenueRuleWithoutCurrency:
      return "revenueCurrency is required for revenue rules"
    }
  }
}

/// Config-driven conversion-value engine: the SDK accumulates events and
/// revenue, this decides what to report, and the platform layer makes the call.
public struct ConversionValueMapper: Sendable {
  private let rules: [ConversionValueRule]
  private let defaultCoarse: CoarseValue
  private let revenueCurrency: String?

  /// Validation happens here rather than at `compute` on purpose: a config
  /// mistake should surface when the config is loaded, not silently report fine
  /// value 0 from every device for a week.
  public init(_ config: ConversionValueConfig) throws {
    for rule in config.rules {
      guard (0...63).contains(rule.fineValue) else {
        throw ConversionConfigError.fineValueOutOfRange(rule.fineValue)
      }
      if let micros = rule.minRevenueMicros, !isCanonicalMicros(micros) {
        throw ConversionConfigError.malformedMicros(micros)
      }
    }
    if let currency = config.revenueCurrency, !isIsoCurrency(currency) {
      throw ConversionConfigError.malformedCurrency(currency)
    }
    if config.rules.contains(where: { $0.minRevenueMicros != nil }),
      config.revenueCurrency == nil
    {
      throw ConversionConfigError.revenueRuleWithoutCurrency
    }

    self.rules = config.rules
    self.defaultCoarse = config.defaultCoarse ?? .low
    self.revenueCurrency = config.revenueCurrency
  }

  /// The **highest** matching rule wins, not the first or the last: rule order
  /// in a config is an authoring convenience and must not change the outcome.
  public func compute(_ state: MeasurementState) -> ConversionValue {
    var winner: ConversionValueRule?
    for rule in rules where matches(rule, state) {
      if winner == nil || rule.fineValue > winner!.fineValue { winner = rule }
    }
    guard let winner else {
      return ConversionValue(fineValue: 0, coarseValue: defaultCoarse)
    }
    return ConversionValue(
      fineValue: winner.fineValue,
      coarseValue: winner.coarseValue ?? deriveCoarse(winner.fineValue))
  }

  private func matches(_ rule: ConversionValueRule, _ state: MeasurementState) -> Bool {
    if let threshold = rule.minRevenueMicros {
      guard let accrued = state.revenueMicros, isCanonicalMicros(accrued) else { return false }
      // A denomination mismatch arises legitimately when the app changes its
      // SKAN currency mid-window: persisted device state still holds revenue in
      // the old one. That revenue is unusable for this comparison, so the rule
      // does not match. Throwing here froze the device's conversion value for
      // the rest of the window, because every later evaluation re-threw into
      // the SDK's fire-and-forget catch.
      guard state.revenueCurrency == revenueCurrency else { return false }
      if microsLess(accrued, threshold) { return false }
    }
    if let required = rule.events, !required.allSatisfy(state.events.contains) {
      return false
    }
    return true
  }
}

/// Exact comparison of canonical non-negative base-10 integers, without a
/// bignum: more digits is larger, and equal digit counts compare
/// lexicographically. A `Double` would make neighbouring large micro amounts
/// compare equal and silently misprice a conversion.
public func microsLess(_ lhs: String, _ rhs: String) -> Bool {
  lhs.count != rhs.count ? lhs.count < rhs.count : lhs < rhs
}

/// Parses a non-negative decimal amount ("9.99") into exact millionths,
/// returning nil for anything that is not one. Digit-string arithmetic, not
/// `Double`: at 2^53 a Double can no longer count, and below that it cannot
/// represent 0.07 — both failures misprice a conversion by real money.
///
/// The grammar matches `decimalToMicros` in `@advenue/skadnetwork`: no leading
/// zeros, at most six fractional places, no sign and no exponent.
public func decimalToMicros(_ amount: String) -> String? {
  guard !amount.isEmpty, amount.allSatisfy(\.isASCII) else { return nil }
  let parts = amount.split(separator: ".", omittingEmptySubsequences: false)
  guard parts.count <= 2 else { return nil }
  let whole = String(parts[0])
  let fraction = parts.count == 2 ? String(parts[1]) : ""

  guard !whole.isEmpty, whole.allSatisfy(\.isNumber) else { return nil }
  guard whole == "0" || whole.first != "0" else { return nil }
  if parts.count == 2 {
    guard !fraction.isEmpty, fraction.count <= 6, fraction.allSatisfy(\.isNumber) else {
      return nil
    }
  }

  let digits = whole + fraction.padding(toLength: 6, withPad: "0", startingAt: 0)
  // Canonicalise: "0.000001" produces "0000001", and the queue's exact
  // comparison is defined only on values with no leading zeros.
  let trimmed = String(digits.drop(while: { $0 == "0" }))
  return trimmed.isEmpty ? "0" : trimmed
}

/// No leading zeros except "0" itself, digits only — the same shape the server
/// accepts, so a value that passes here cannot be rejected there.
func isCanonicalMicros(_ value: String) -> Bool {
  guard !value.isEmpty, value.allSatisfy(\.isASCII), value.allSatisfy({ $0.isNumber }) else {
    return false
  }
  return value == "0" || value.first != "0"
}

func isIsoCurrency(_ value: String) -> Bool {
  value.count == 3 && value.allSatisfy { $0.isUppercase && $0.isASCII && $0.isLetter }
}

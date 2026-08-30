import AdvenueCore
import Foundation

/// The SDK's own UserDefaults suite. **This exact name is a compatibility
/// requirement**, not a preference: the React Native module writes here, and
/// the RN inversion (sub-project 3) has to find the same queue, session state
/// and install flag. A different suite silently orphans every install.
public let ADVENUE_SUITE = "io.advenue.sdk"

/// A dedicated suite keeps SDK keys out of the host app's defaults.
///
/// `@unchecked Sendable` is an assertion, and this one is true: Apple
/// documents `UserDefaults` as thread-safe. It is not the same move as
/// declaring `EventQueue` unchecked would have been — that type genuinely is
/// not thread-safe, so the assertion would have been false and the compiler
/// would have been silenced rather than satisfied.
public struct UserDefaultsStore: KeyValueStore, @unchecked Sendable {
  private let defaults: UserDefaults

  public init(suiteName: String = ADVENUE_SUITE) {
    self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
  }

  public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
  public func set(_ value: String, forKey key: String) { defaults.set(value, forKey: key) }
  public func removeObject(forKey key: String) { defaults.removeObject(forKey: key) }
}

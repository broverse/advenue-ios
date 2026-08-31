import Foundation

/// What the core needs from SKAdNetwork, and no more.
///
/// Declared here so `AdvenueCore` keeps importing only Foundation while still
/// owning the decision of *when* to report — that decision is what the tests
/// can settle, and the Apple call is what they cannot.
public protocol SkanReporter: Sendable {
  /// Registers the install for attribution. Apple wants this at first launch;
  /// a late call loses the attribution window.
  func register()

  /// Reports a conversion value. Throws when the platform refuses it, and the
  /// caller must NOT confirm a throw — a device that recorded a value it never
  /// sent would refuse to send it again, and that window would report nothing
  /// for the rest of its life.
  func update(fine: Int, coarse: CoarseValue, lockWindow: Bool) async throws
}

/// A reporter that does nothing, for platforms and configurations with no SKAN.
public struct NoopSkanReporter: SkanReporter {
  public init() {}
  public func register() {}
  public func update(fine: Int, coarse: CoarseValue, lockWindow: Bool) async throws {}
}

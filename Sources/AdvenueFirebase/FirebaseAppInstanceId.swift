import Advenue
import Foundation

#if canImport(FirebaseAnalytics)
  import FirebaseAnalytics
#endif

/// Supplies the Firebase Analytics app instance id.
///
/// This lives in its own product for one reason: declaring FirebaseAnalytics
/// in the base target would force it on every consumer, including those who
/// never touch Firebase. The RN module gets away with `#if canImport` because
/// CocoaPods links the host app's pods together; under SPM `canImport` is
/// false unless the dependency is declared, so a separate product is the only
/// correct shape. Adjust draws the same base/plugin line.
public enum AdvenueFirebase {
  /// Registers the provider with the SDK. Call after `Advenue.initialize`.
  public static func register() {
    Advenue.setAppInstanceIdProvider { await appInstanceId() }
  }

  /// Nil when Firebase is absent — the SDK carries on without the field
  /// rather than failing, since an app instance id is an enrichment and not a
  /// requirement for attribution.
  public static func appInstanceId() async -> String? {
    #if canImport(FirebaseAnalytics)
      return await withCheckedContinuation { continuation in
        Analytics.appInstanceID { id, _ in continuation.resume(returning: id) }
      }
    #else
      return nil
    #endif
  }
}

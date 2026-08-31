import AdvenueCore
import Foundation

#if os(iOS)
  import StoreKit
#endif

/// SKAdNetwork through StoreKit.
///
/// Three API generations, and an OS with none of them must do nothing rather
/// than trap: an SDK that crashes on an old device takes the host app down with
/// it, and SKAN is the least important thing it does.
///
/// On macOS — where the host test suite runs — SKAdNetwork does not exist at
/// all, so this degrades to nothing. `canImport(StoreKit)` is the wrong gate
/// and compiles happily before failing on the symbol: StoreKit is there, SKAN
/// is not.
///
/// **The simulator implements all of this as a no-op that reports success.** A
/// simulator test of this type therefore asserts nothing about Apple; what the
/// tests here settle is the availability decision and the coarse mapping. That
/// a postback actually arrives carrying the value is a device claim, and it is
/// on the checklist rather than implied here.
public struct StoreKitSkanReporter: SkanReporter {
  private let onError: @Sendable (String, any Error) -> Void

  public init(onError: @escaping @Sendable (String, any Error) -> Void = { _, _ in }) {
    self.onError = onError
  }

  public func register() {
    #if os(iOS)
      if #available(iOS 16.1, *) {
        // The modern form registers implicitly on the first conversion update,
        // but calling it explicitly is what starts the window for an install
        // that never converts — which is most of them.
        SKAdNetwork.updatePostbackConversionValue(0) { error in
          if let error { onError("skan.register", error) }
        }
      } else if #available(iOS 14.0, *) {
        SKAdNetwork.registerAppForAdNetworkAttribution()
      }
    #endif
  }

  public func update(fine: Int, coarse: CoarseValue, lockWindow: Bool) async throws {
    #if os(iOS)
      if #available(iOS 16.1, *) {
        try await SKAdNetwork.updatePostbackConversionValue(
          fine, coarseValue: coarse.storeKitValue, lockWindow: lockWindow)
        return
      }
      if #available(iOS 15.4, *) {
        // No coarse value before 16.1. Sending the fine value alone is still
        // worth doing: v3-signed ads read it.
        try await SKAdNetwork.updatePostbackConversionValue(fine)
        return
      }
      if #available(iOS 14.0, *) {
        SKAdNetwork.updateConversionValue(fine)
        return
      }
    #endif
    // No SKAN on this OS. Not an error worth surfacing — there is nothing the
    // app or the SDK could do about it.
  }
}

#if os(iOS)
  extension CoarseValue {
    /// Apple's own enum. Mapping this wrong silently files every postback in
    /// the wrong bucket, and nothing downstream can detect it.
    @available(iOS 16.1, *)
    var storeKitValue: SKAdNetwork.CoarseConversionValue {
      switch self {
      case .low: return .low
      case .medium: return .medium
      case .high: return .high
      }
    }
  }
#endif

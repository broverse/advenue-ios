import AdvenueCore
import Foundation

#if os(iOS)
  import StoreKit

  #if canImport(AdAttributionKit)
    import AdAttributionKit
  #endif
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
/// **What a simulator does here, measured rather than assumed:** it does NOT
/// silently succeed. `updatePostbackConversionValue` answers
/// `SKANErrorDomain 10` when there is no ad impression to attach a value to,
/// which is also what a real device with no impression does. So the simulator
/// exercises the SDK's degradation path for real — the caller abandons the
/// value and reports it — and that is worth more than the no-op this comment
/// originally claimed.
///
/// What it still cannot settle is the success path: that a postback arrives
/// carrying the value we sent needs a device with a signed impression, and it
/// is on the checklist rather than implied here.
public struct StoreKitSkanReporter: SkanReporter {
  private let onError: @Sendable (String, any Error) -> Void
  private let adAttributionUpdate: @Sendable (Int, CoarseValue, Bool) async throws -> Void

  public init(
    onError: @escaping @Sendable (String, any Error) -> Void = { _, _ in },
    adAttributionUpdate: (@Sendable (Int, CoarseValue, Bool) async throws -> Void)? = nil
  ) {
    self.onError = onError
    self.adAttributionUpdate = adAttributionUpdate ?? Self.systemAdAttributionUpdate
  }

  /// AdAttributionKit, iOS 17.4+. An impression may be signed for either rail,
  /// so both are updated rather than one chosen.
  ///
  /// Injectable because the invariant that matters cannot otherwise be tested:
  /// a failure here is **expected** whenever no AAK-signed impression exists,
  /// and it must not fail the SKAN update. If it did, a device with only a
  /// SKAN-signed impression would never confirm its value and that window would
  /// report nothing for the rest of its life.
  @Sendable
  private static func systemAdAttributionUpdate(
    fine: Int, coarse: CoarseValue, lockWindow: Bool
  ) async throws {
    #if os(iOS) && canImport(AdAttributionKit)
      if #available(iOS 17.4, *) {
        try await Postback.updateConversionValue(
          fine, coarseConversionValue: coarse.adAttributionValue,
          lockPostback: lockWindow)
      }
    #endif
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
    // AdAttributionKit first, and its failure is swallowed on purpose: it is
    // the expected answer when no AAK-signed impression exists. Letting it
    // propagate would abandon a perfectly good SKAN value.
    do {
      try await adAttributionUpdate(fine, coarse, lockWindow)
    } catch {
      onError("skan.adAttributionKit", error)
    }

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

#if os(iOS) && canImport(AdAttributionKit)
  extension CoarseValue {
    /// AdAttributionKit's own enum, distinct from StoreKit's.
    @available(iOS 17.4, *)
    var adAttributionValue: AdAttributionKit.CoarseConversionValue {
      switch self {
      case .low: return .low
      case .medium: return .medium
      case .high: return .high
      }
    }
  }
#endif

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

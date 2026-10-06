import Foundation

#if canImport(AdSupport)
  import AdSupport
#endif
#if canImport(AppTrackingTransparency)
  import AppTrackingTransparency
#endif
#if canImport(UIKit)
  import UIKit
#endif

public enum TrackingAuthorization: String, Sendable {
  case notDetermined = "not_determined"
  case restricted
  case denied
  case authorized
}

/// The all-zero IDFA. Apple returns it when tracking is not authorised, and it
/// is not an identifier — it must never travel as one, or every unauthorised
/// device looks like the same device.
public let ZERO_IDFA = "00000000-0000-0000-0000-000000000000"

/// The advertising identity as one snapshot: what the flush/foreground
/// refresh hands the core. A named struct rather than a tuple — tuples are
/// fine until they cross a boundary that wants a name.
public struct AdvertisingSnapshot: Sendable, Equatable {
  public var idfa: String?
  public var vendorId: String?
  public var limitAdTracking: Bool

  public init(idfa: String? = nil, vendorId: String? = nil, limitAdTracking: Bool = false) {
    self.idfa = idfa
    self.vendorId = vendorId
    self.limitAdTracking = limitAdTracking
  }
}

/// ATT, IDFA and the vendor id.
///
/// The SDK never prompts on its own: Apple gives the app control of the
/// timing, an early call silently answers `notDetermined`, and a prompt the
/// user did not expect is a review risk that is not the SDK's to take.
public struct AdvertisingIdentity: Sendable {
  public init() {}

  public var status: TrackingAuthorization {
    #if canImport(AppTrackingTransparency)
      switch ATTrackingManager.trackingAuthorizationStatus {
      case .authorized: return .authorized
      case .denied: return .denied
      case .restricted: return .restricted
      default: return .notDetermined
      }
    #else
      return .notDetermined
    #endif
  }

  /// The IDFA, or nil when it is unavailable or all zeros.
  public var advertisingId: String? {
    #if canImport(AdSupport)
      guard status == .authorized else { return nil }
      let id = ASIdentifierManager.shared().advertisingIdentifier.uuidString
      return id == ZERO_IDFA ? nil : id
    #else
      return nil
    #endif
  }

  /// Available without ATT because it is not an advertising identifier.
  /// First-party fraud and dedup only — never cross-network attribution, which
  /// would be "tracking" under Apple's policy.
  public var vendorId: String? {
    #if canImport(UIKit)
      return onMainSync { UIDevice.current.identifierForVendor?.uuidString }
    #else
      return nil
    #endif
  }

  /// True when the user limited tracking. This is the field that separates
  /// "denied" from "organic" on the server, so a false value here sends a
  /// consent signal the user never gave.
  public var limitAdTracking: Bool {
    status == .denied || status == .restricted
  }

  /// The current values as one snapshot. Three synchronous getters — cheap
  /// enough to call on every flush, which is exactly what the refresh does.
  public func snapshot() -> AdvertisingSnapshot {
    AdvertisingSnapshot(
      idfa: advertisingId, vendorId: vendorId, limitAdTracking: limitAdTracking)
  }

  /// Presents the system prompt. The app decides when.
  public func requestAuthorization() async -> TrackingAuthorization {
    #if canImport(AppTrackingTransparency)
      return await withCheckedContinuation { continuation in
        ATTrackingManager.requestTrackingAuthorization { _ in
          continuation.resume(returning: self.status)
        }
      }
    #else
      return .notDetermined
    #endif
  }
}

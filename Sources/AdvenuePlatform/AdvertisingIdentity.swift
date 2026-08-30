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
      return UIDevice.current.identifierForVendor?.uuidString
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

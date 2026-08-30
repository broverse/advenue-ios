import Foundation
import Security

/// The answer to a secure read. The three cases are genuinely different, and
/// collapsing `unavailable` into `absent` is the bug this type exists to
/// prevent.
public enum SecureReadResult: Equatable, Sendable {
  /// A value is stored and readable.
  case found(String)
  /// No such item. A caller may mint a new identity.
  case absent
  /// The item exists or may exist, but it cannot be read —
  /// `errSecInteractionNotAllowed` on an `AfterFirstUnlock` item before the
  /// first unlock after a reboot. A caller MUST NOT mint a new identity:
  /// silent push can background-launch the app in exactly this window, and a
  /// fresh device id there means a phantom device and a phantom install.
  case unavailable
}

/// Storage that survives app uninstall. `device_id` lives here; the
/// installation id and install flag live in UserDefaults precisely because
/// they must NOT survive — reinstall detection rests on that asymmetry.
public protocol SecureStore: Sendable {
  func read(_ key: String) -> SecureReadResult
  func write(_ value: String, forKey key: String)
  func delete(_ key: String)
}

public struct KeychainStore: SecureStore {
  /// Shared with the App Attest key id under a different account, matching the
  /// RN module. Same service, distinct accounts, so neither can read the
  /// other's entry.
  public static let service = "io.advenue.sdk"

  public init() {}

  private func baseQuery(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: key,
    ]
  }

  /// Maps a Keychain result to the three answers the SDK distinguishes.
  ///
  /// Split out as a pure function because it is the part that decides whether
  /// a device id gets invented, and it is testable without Keychain access —
  /// which an unsigned XCTest bundle in the simulator does not have
  /// (`errSecMissingEntitlement`). The round-trip needs a signed host app or a
  /// real device; this decision does not, and it is where the bug was.
  public static func interpret(status: OSStatus, data: Data?) -> SecureReadResult {
    switch status {
    case errSecSuccess:
      guard let data, let value = String(data: data, encoding: .utf8) else { return .absent }
      return .found(value)
    case errSecItemNotFound:
      return .absent
    default:
      // errSecInteractionNotAllowed (locked), errSecMissingEntitlement, and
      // every other error land here. Treating any of them as "no value" is
      // what would invent a device.
      return .unavailable
    }
  }

  public func read(_ key: String) -> SecureReadResult {
    var query = baseQuery(key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return Self.interpret(status: status, data: result as? Data)
  }

  public func write(_ value: String, forKey key: String) {
    guard let data = value.data(using: .utf8) else { return }
    let base = baseQuery(key)
    let status = SecItemUpdate(
      base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var add = base
      add[kSecValueData as String] = data
      // AfterFirstUnlock so a background launch after reboot can read it;
      // ThisDeviceOnly so an iCloud restore cannot put one device's identity
      // on another, which would merge two devices into one.
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      SecItemAdd(add as CFDictionary, nil)
    }
  }

  public func delete(_ key: String) {
    SecItemDelete(baseQuery(key) as CFDictionary)
  }
}

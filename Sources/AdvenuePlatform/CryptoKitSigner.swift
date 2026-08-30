import AdvenueCore
import CryptoKit
import Foundation

/// Production HMAC-SHA256. `AdvenueCore` never imports CryptoKit — that is
/// what lets its conformance vectors build and run on Linux — so the
/// implementation is injected from here.
///
/// This type and the swift-crypto one used by the core's tests are verified
/// against the SAME signing vectors, which is how their agreement is
/// established without compiling both into one binary.
public struct CryptoKitSigner: Signer {
  public init() {}

  public func hmacSHA256Hex(secret: String, message: String) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
    return mac.map { String(format: "%02x", $0) }.joined()
  }
}

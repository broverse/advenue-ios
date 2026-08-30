import Crypto
import Foundation
import XCTest

@testable import AdvenueCore

/// swift-crypto HMAC, used ONLY by tests. Production signing is CryptoKit in
/// AdvenuePlatform; both are verified against the same vectors, which is what
/// makes their agreement provable without compiling both in one binary.
struct CryptoKitTestSigner: Signer {
  func hmacSHA256Hex(secret: String, message: String) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
    return mac.map { String(format: "%02x", $0) }.joined()
  }
}

final class SigningVectorTests: XCTestCase {
  func testSigningVectors() throws {
    let signer = CryptoKitTestSigner()
    let vectors = try loadVectors("signing")
    XCTAssertFalse(vectors.isEmpty, "signing vectors must be bundled")

    for vector in vectors {
      let input: [String: Any] = try vector.value("input")
      let secret = input["secret"] as! String
      let timestamp = input["timestamp"] as! String
      let body = input["body"] as! String

      let signature = signRequest(signer, secret: secret, timestamp: timestamp, body: body)

      XCTAssertEqual(signature.count, 64, "\(vector.file): \(vector.name)")
      XCTAssertEqual(
        signature, signature.lowercased(), "\(vector.file): digest must be lowercase hex")
      XCTAssertEqual(
        signature, Self.expected[vector.file],
        """
        \(vector.file) — \(vector.name)
        The expected value comes from the TypeScript snapshot in
        packages/sdk-core/src/__snapshots__/conformance.test.ts.snap.
        A mismatch means the two implementations disagree on the wire.
        """)
    }
  }

  /// Values recorded by the TypeScript runner for the same vectors. Copied
  /// deliberately rather than computed: the point is that two independent
  /// implementations produce the same bytes.
  static let expected: [String: String] = [
    "basic.json": "9ab0cd868afcea3460021dbe2b1c7f2d964be29a25e14b416aa5f8eb3c9899ef",
    "empty-body.json": "e4bd0dfa59a710d6c6cc505ef0b1756970fc63fa9c82f0998bfdf4b9ff0c6cd7",
    "unicode-body.json": "66c12ad1eacaa5033f218245c18f1419472f359a2cef4d139ba2b8fb4b17dbbd",
  ]
}

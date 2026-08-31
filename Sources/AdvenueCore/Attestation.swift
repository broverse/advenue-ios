import Foundation

/// What App Attest produces: the key Apple minted and the CBOR attestation
/// object the server verifies against it.
public struct AttestationResult: Equatable, Sendable {
  public let keyId: String
  /// Base64. Passed straight through to the server's verifier.
  public let attestationObject: String

  public init(keyId: String, attestationObject: String) {
    self.keyId = keyId
    self.attestationObject = attestationObject
  }
}

public enum AttestationError: Error, Equatable, CustomStringConvertible {
  /// The device cannot attest at all — every simulator, and every Mac. Distinct
  /// from a failure so the caller can omit the fields quietly rather than retry
  /// something that can never work.
  case unsupported
  case badChallenge
  case keyGeneration
  case attestFailed

  public var description: String {
    switch self {
    case .unsupported: return "device attestation is not supported here"
    case .badChallenge: return "the challenge could not be encoded as UTF-8"
    case .keyGeneration: return "App Attest key generation failed"
    case .attestFailed: return "attestKey failed"
    }
  }
}

/// Device attestation, injected so the install path can be tested without a
/// device — which is the only way it can be tested, since
/// `DCAppAttestService.isSupported` is false in every simulator.
public protocol Attestation: Sendable {
  /// Attests a server-issued challenge. Throws rather than returning nil so the
  /// caller can tell "cannot" from "did not".
  func attest(challenge: String) async throws -> AttestationResult

  /// The legacy DeviceCheck token: two bits of per-device state Apple keeps
  /// across reinstalls, which is what makes it useful for reinstall abuse.
  func deviceCheckToken() async throws -> String
}

/// Where the one-time challenge comes from. It is server-issued and single-use,
/// so it cannot be generated on the device.
public protocol ChallengeSource: Sendable {
  func challenge(deviceId: String) async throws -> String
}

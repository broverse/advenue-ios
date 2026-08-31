import AdvenueCore
import CryptoKit
import Foundation

#if canImport(DeviceCheck)
  import DeviceCheck
#endif

/// App Attest and DeviceCheck, ported from the React Native module.
///
/// **Unavailable in every simulator.** `DCAppAttestService.isSupported` and
/// `DCDevice.isSupported` are both false there, so the tests here settle that we
/// degrade rather than crash and that the key cache behaves — not that Apple
/// produces a verifiable attestation. That is a device claim and it is on the
/// checklist.
public struct DeviceCheckAttestation: Attestation {
  /// The cached key id. Apple charges for `generateKey`, and more importantly a
  /// key can be attested only once, so the id has to outlive the call.
  public static let KEY_ID_KEY = "advenue.appattest.key_id"

  private let secure: any SecureStore

  public init(secure: any SecureStore) {
    self.secure = secure
  }

  /// The server re-derives this hash from the same challenge, so these bytes
  /// are a contract rather than an implementation detail.
  public static func clientDataHash(challenge: String) throws -> Data {
    guard let bytes = challenge.data(using: .utf8) else {
      throw AttestationError.badChallenge
    }
    return Data(SHA256.hash(data: bytes))
  }

  public func attest(challenge: String) async throws -> AttestationResult {
    #if canImport(DeviceCheck)
      guard #available(iOS 14.0, *) else { throw AttestationError.unsupported }
      let service = DCAppAttestService.shared
      guard service.isSupported else { throw AttestationError.unsupported }

      let hash = try Self.clientDataHash(challenge: challenge)
      let keyId = try await resolveKeyId(service)

      do {
        let object = try await service.attestKey(keyId, clientDataHash: hash)
        return AttestationResult(
          keyId: keyId, attestationObject: object.base64EncodedString())
      } catch {
        // A key can be attested only once. When Apple calls a cached id
        // invalid — it was already attested, or it went bad — that id is
        // permanently dead. Dropping it makes the NEXT call generate a fresh
        // key; keeping it makes every later attempt loop on a corpse.
        if (error as? DCError)?.code == .invalidKey {
          secure.delete(Self.KEY_ID_KEY)
        }
        throw AttestationError.attestFailed
      }
    #else
      throw AttestationError.unsupported
    #endif
  }

  public func deviceCheckToken() async throws -> String {
    #if canImport(DeviceCheck)
      guard DCDevice.current.isSupported else { throw AttestationError.unsupported }
      let data = try await DCDevice.current.generateToken()
      return data.base64EncodedString()
    #else
      throw AttestationError.unsupported
    #endif
  }

  #if canImport(DeviceCheck)
    @available(iOS 14.0, *)
    private func resolveKeyId(_ service: DCAppAttestService) async throws -> String {
      if case .found(let cached) = secure.read(Self.KEY_ID_KEY) { return cached }
      do {
        let generated = try await service.generateKey()
        secure.write(generated, forKey: Self.KEY_ID_KEY)
        return generated
      } catch {
        throw AttestationError.keyGeneration
      }
    }
  #endif
}

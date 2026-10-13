import AdvenueCore
import Foundation

/// The server half of `resetInstall()` (spec 3 §7): clears the device's
/// sandbox (`sbx:`) state. Never touches production.
public protocol SandboxDeviceResetting: Sendable {
  func reset(deviceId: String, installationId: String?) async throws
}

/// Synthesized `Encodable` writes a nil `installationId` with
/// `encodeIfPresent`, so the field is absent rather than null.
struct ResetDeviceBody: Encodable {
  let apiKey: String
  let platform: String
  let deviceId: String
  let installationId: String?
}

/// Signed `POST /v1/sandbox/reset-device`, the same API key and HMAC as
/// `/v1/events`. The signing secret is the caller's runtime config; the SDK
/// embeds none.
public struct HttpSandboxDeviceReset: SandboxDeviceResetting {
  private let endpoint: String
  private let apiKey: String
  private let signingSecret: String?
  private let signer: any Signer
  private let clock: any Clock
  private let session: URLSession

  public init(
    endpoint: String = DEFAULT_ENDPOINT,
    apiKey: String,
    signingSecret: String? = nil,
    signer: any Signer = CryptoKitSigner(),
    clock: any Clock = SystemClock(),
    session: URLSession = .shared
  ) {
    self.endpoint = endpoint
    self.apiKey = apiKey
    self.signingSecret = signingSecret
    self.signer = signer
    self.clock = clock
    self.session = session
  }

  public func buildRequest(deviceId: String, installationId: String?) throws -> URLRequest {
    let nowMs = clock.nowMs()
    let body = try EventEncoding.canonicalEncoder().encode(
      ResetDeviceBody(
        apiKey: apiKey, platform: "ios", deviceId: deviceId, installationId: installationId))
    var request = URLRequest(url: URL(string: "\(endpoint)/v1/sandbox/reset-device")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = body
    request.timeoutInterval = 15
    if let secret = signingSecret {
      let timestamp = String(nowMs)
      request.setValue(timestamp, forHTTPHeaderField: "X-Advenue-Timestamp")
      request.setValue(
        signRequest(
          signer, secret: secret, timestamp: timestamp, body: String(decoding: body, as: UTF8.self)),
        forHTTPHeaderField: "X-Advenue-Signature")
    }
    return request
  }

  /// Throws `IngestError` with the server's status (404 from a server that
  /// predates the route, 429 `rate_limited`), or 408 with a network cause.
  public func reset(deviceId: String, installationId: String?) async throws {
    let request = try buildRequest(deviceId: deviceId, installationId: installationId)
    let response: URLResponse
    do {
      (_, response) = try await session.data(for: request)
    } catch {
      throw IngestError(status: 408, networkCause: describeNetworkFailure(error))
    }
    guard let http = response as? HTTPURLResponse else { throw IngestError(status: 408) }
    guard (200..<300).contains(http.statusCode) else { throw IngestError(status: http.statusCode) }
  }
}

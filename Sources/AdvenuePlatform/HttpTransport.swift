import AdvenueCore
import Foundation

/// What the SDK POSTs. `apiKey` travels in the body, matching
/// `eventBatchSchema`.
struct EventBatch: Encodable {
  let apiKey: String
  let events: [ClientEvent]
  /// The device clock at THIS send attempt (spec 2026-10-01-data-fidelity D3).
  /// The server compares it with its receive time to measure the clock offset,
  /// so it is stamped on every attempt and never persisted with the queue.
  let sentAt: String
  /// Spec 2 §2.1: present only for sandbox; production omits it.
  let environment: String?
}

public let DEFAULT_ENDPOINT = "https://ingest.advenue.io"
/// The schema caps a batch at 100 events.

/// Batched ingest over URLSession.
///
/// Throws `IngestError` on a non-2xx so the caller can distinguish a transient
/// failure from a poison payload; a transport failure maps to 408, matching
/// sdk-core so both SDKs retry exactly the same cases.
public struct HttpTransport: EventTransport, Sendable {
  private let endpoint: String
  private let apiKey: String
  private let signingSecret: String?
  private let signer: any Signer
  private let clock: any Clock
  private let session: URLSession
  private let environment: AdvenueEnvironment
  private let capability: SandboxCapability?
  /// Receives the app the server reported for an ACCEPTED batch. Purely
  /// diagnostic: it runs after the batch is already accepted, so nothing it
  /// does can turn a successful ingest into a failure.
  private let onAccepted: @Sendable (String) -> Void

  public init(
    endpoint: String = DEFAULT_ENDPOINT,
    apiKey: String,
    signingSecret: String? = nil,
    signer: any Signer = CryptoKitSigner(),
    clock: any Clock = SystemClock(),
    session: URLSession = .shared,
    environment: AdvenueEnvironment = .production,
    capability: SandboxCapability? = nil,
    onAccepted: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.onAccepted = onAccepted
    self.endpoint = endpoint
    self.apiKey = apiKey
    self.signingSecret = signingSecret
    self.signer = signer
    self.clock = clock
    self.session = session
    self.environment = environment
    // One per transport, and the facade builds one transport per start: so
    // the capability is asked once per process, before the first upload.
    self.capability =
      environment == .sandbox
      ? (capability ?? SandboxCapability.http(endpoint: endpoint, session: session)) : nil
  }

  /// The exact request this transport would send. Public so a test can assert
  /// the wire shape — endpoint, headers, body, signature — without a network
  /// round trip, which is the part that has to be right.
  public func buildRequest(_ events: [ClientEvent]) throws -> URLRequest {
    // One reading for both `sentAt` and the signed timestamp: they describe
    // the same instant, and two reads could straddle a clock change.
    let nowMs = clock.nowMs()
    let body = try EventEncoding.canonicalEncoder()
      .encode(
        EventBatch(
          apiKey: apiKey, events: events, sentAt: EventEncoding.iso8601(ms: nowMs),
          environment: environment == .sandbox ? AdvenueEnvironment.sandbox.rawValue : nil))
    var request = URLRequest(url: URL(string: "\(endpoint)/v1/events")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = body
    request.timeoutInterval = 15

    if let secret = signingSecret {
      let timestamp = String(nowMs)
      request.setValue(timestamp, forHTTPHeaderField: "X-Advenue-Timestamp")
      request.setValue(
        signRequest(
          signer, secret: secret, timestamp: timestamp,
          body: String(decoding: body, as: UTF8.self)),
        forHTTPHeaderField: "X-Advenue-Signature")
    }
    return request
  }

  public func send(_ events: [ClientEvent]) async throws {
    if let capability {
      let supported = try await capability.check()
      if !supported { throw SandboxUnsupportedError(.capabilityMissing) }
    }
    let request = try buildRequest(events)
    let response: URLResponse
    let payload: Data
    do {
      (payload, response) = try await session.data(for: request)
    } catch {
      // No status to reason about. 408 marks it retryable, which is what
      // sdk-core does for the same case; the cause says it was the network.
      throw IngestError(status: 408, networkCause: describeNetworkFailure(error))
    }
    guard let http = response as? HTTPURLResponse else { throw IngestError(status: 408) }
    // Diagnostics only: the batch is already accepted when an app id comes back.
    if let appId = try Self.interpret(
      status: http.statusCode, body: payload, environment: environment)
    {
      onAccepted(appId)
    }
  }

  /// The verdict on one response. Pure, so the sandbox rules are testable
  /// without a network. Returns the app id the server resolved, if any.
  static func interpret(status: Int, body: Data, environment: AdvenueEnvironment) throws -> String? {
    let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    guard (200..<300).contains(status) else {
      if status == 429, json?["error"] as? String == "sandbox_quota_exceeded",
        let reset = (json?["resetAtMs"] as? NSNumber)?.int64Value
      {
        throw IngestError(status: 429, quotaResetAtMs: reset)
      }
      throw IngestError(status: status)
    }
    // Second line of defence (spec 2 §7.2): a proxy can serve an old
    // ingestion behind a new /health.
    if environment == .sandbox, json?["environment"] as? String != "sandbox" {
      throw SandboxUnsupportedError(.responseMismatch)
    }
    guard let appId = json?["appId"] as? String, !appId.isEmpty else { return nil }
    return appId
  }
}

/// A short, identifier-free name for a failure that produced no response.
func describeNetworkFailure(_ error: any Error) -> String {
  guard let urlError = error as? URLError else { return String(describing: type(of: error)) }
  switch urlError.code {
  case .notConnectedToInternet: return "not connected to the internet"
  case .timedOut: return "timed out"
  case .cannotFindHost, .dnsLookupFailed: return "host not found"
  case .cannotConnectToHost: return "connection refused"
  case .networkConnectionLost: return "connection lost"
  case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
    .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
    return "TLS failure"
  default: return "URLError \(urlError.code.rawValue)"
  }
}

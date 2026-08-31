import AdvenueCore
import Foundation

/// What the SDK POSTs. `apiKey` travels in the body, matching
/// `eventBatchSchema`.
struct EventBatch: Encodable {
  let apiKey: String
  let events: [ClientEvent]
}

public let DEFAULT_ENDPOINT = "https://ingest.advenue.io"
/// The schema caps a batch at 100 events.
public let MAX_BATCH_SIZE = 100

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

  /// The exact request this transport would send. Public so a test can assert
  /// the wire shape — endpoint, headers, body, signature — without a network
  /// round trip, which is the part that has to be right.
  public func buildRequest(_ events: [ClientEvent]) throws -> URLRequest {
    let body = try EventEncoding.canonicalEncoder()
      .encode(EventBatch(apiKey: apiKey, events: events))
    var request = URLRequest(url: URL(string: "\(endpoint)/v1/events")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = body
    request.timeoutInterval = 15

    if let secret = signingSecret {
      let timestamp = String(clock.nowMs())
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
    let request = try buildRequest(events)
    let response: URLResponse
    do {
      (_, response) = try await session.data(for: request)
    } catch {
      // No status to reason about. 408 marks it retryable, which is what
      // sdk-core does for the same case.
      throw IngestError(status: 408)
    }
    guard let http = response as? HTTPURLResponse else { throw IngestError(status: 408) }
    guard (200..<300).contains(http.statusCode) else {
      throw IngestError(status: http.statusCode)
    }
  }
}

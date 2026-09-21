import AdvenueCore
import Foundation

/// Fetches the one-time App Attest challenge.
///
/// Served by the **ingestion** host, not the dashboard API: the SDK already
/// talks to it and it is the service that will verify the attestation.
public struct HttpChallengeFetcher: ChallengeSource {
  private let endpoint: String
  private let apiKey: String
  private let session: URLSession

  public init(
    endpoint: String = DEFAULT_ENDPOINT, apiKey: String, session: URLSession = .shared
  ) {
    self.endpoint = endpoint
    self.apiKey = apiKey
    self.session = session
  }

  /// The exact request this fetcher would send. Public so a test can assert
  /// the wire shape without a network round trip.
  ///
  /// Sends `?platform=ios`: this fetcher is iOS-only by construction, and a
  /// project-scoped key otherwise cannot resolve a listing on a normal
  /// two-listing (iOS + Android) product — see `resolveProjectListing` in
  /// apps/ingestion/src/app.ts, which 400s an ambiguous project key rather
  /// than guess.
  public func buildRequest(deviceId: String) -> URLRequest {
    let escaped =
      deviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceId
    var request = URLRequest(
      url: URL(string: "\(endpoint)/v1/attest/challenge?deviceId=\(escaped)&platform=ios")!)
    request.httpMethod = "GET"
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    // Matches the deadline the RN SDK uses. Attestation is enrichment: it never
    // holds the install.
    request.timeoutInterval = 5
    return request
  }

  public func challenge(deviceId: String) async throws -> String {
    let request = buildRequest(deviceId: deviceId)
    let (payload, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode)
    else { throw AttestationError.attestFailed }

    guard let body = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
      let challenge = body["challenge"] as? String, !challenge.isEmpty
    else { throw AttestationError.badChallenge }

    return challenge
  }
}

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

  public func challenge(deviceId: String) async throws -> String {
    let escaped =
      deviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceId
    var request = URLRequest(
      url: URL(string: "\(endpoint)/v1/attest/challenge?deviceId=\(escaped)")!)
    request.httpMethod = "GET"
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    // Matches the deadline the RN SDK uses. Attestation is enrichment: it never
    // holds the install.
    request.timeoutInterval = 5

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

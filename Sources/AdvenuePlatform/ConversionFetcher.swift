import AdvenueCore
import Foundation

/// Asks the server what this device was attributed to.
///
/// A `pending` answer means the pipeline has not decided yet. Most devices are
/// organic and will answer pending forever, which is why the caller has a
/// budget rather than a loop.
public struct HttpConversionFetcher: ConversionFetcher {
  private let endpoint: String
  private let apiKey: String
  private let deviceId: String
  private let session: URLSession

  public init(
    endpoint: String = DEFAULT_API_ENDPOINT,
    apiKey: String,
    deviceId: String,
    session: URLSession = .shared
  ) {
    self.endpoint = endpoint
    self.apiKey = apiKey
    self.deviceId = deviceId
    self.session = session
  }

  /// Sends `?platform=ios`: this fetcher is iOS-only by construction, and a
  /// project key spans listings, so the server needs the platform to pick the
  /// one this install was filed under (Y-LINKS-1). Without it the lookup
  /// refused the project key the dashboard mints, and the deferred deep link
  /// never arrived.
  func buildRequest() -> URLRequest {
    let escaped =
      deviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceId
    var request = URLRequest(
      url: URL(string: "\(endpoint)/sdk/conversion-data?deviceId=\(escaped)&platform=ios")!)
    request.httpMethod = "GET"
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.timeoutInterval = 15
    return request
  }

  public func fetch() async throws -> ConversionResult {
    let request = buildRequest()

    let payload: Data
    let response: URLResponse
    do {
      (payload, response) = try await session.data(for: request)
    } catch {
      // No status to reason about; 408 marks it retryable, as sdk-core does.
      throw IngestError(status: 408, networkCause: describeNetworkFailure(error))
    }
    guard let http = response as? HTTPURLResponse else { throw IngestError(status: 408) }
    guard (200..<300).contains(http.statusCode) else {
      throw IngestError(status: http.statusCode)
    }

    guard let body = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
      return .pending
    }
    if body["pending"] as? Bool == true { return .pending }

    return .resolved(
      DeepLink(
        deepLinkValue: body["deepLinkValue"] as? String,
        campaign: body["campaign"] as? String,
        network: body["network"] as? String,
        influencerId: body["influencerId"] as? String))
  }
}

/// The dashboard API, which is where the conversion lookup lives — not the
/// ingest host.
public let DEFAULT_API_ENDPOINT = "https://api.advenue.io"

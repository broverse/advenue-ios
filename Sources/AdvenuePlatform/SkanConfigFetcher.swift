import AdvenueCore
import Foundation

/// Matches the deadline the RN SDK uses. The install does not wait for this
/// beyond it — a config that arrives late applies to the next event.
public let SKAN_CONFIG_TIMEOUT_MS = 3_000

/// Fetches the conversion-value config the dashboard serves.
///
/// This is what makes SKAN configurable at all: a conversion schema is tuned
/// constantly and an app release cycle is weeks, so a config that can only be
/// changed by shipping a new binary is a config nobody changes.
public struct HttpSkanConfigFetcher: SkanConfigSource {
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

  public func fetch(etag: String?) async throws -> SkanConfigResult {
    var request = URLRequest(url: URL(string: "\(endpoint)/v1/sdk-config")!)
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    if let etag { request.setValue(etag, forHTTPHeaderField: "if-none-match") }
    request.timeoutInterval = Double(SKAN_CONFIG_TIMEOUT_MS) / 1000

    let (payload, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw IngestError(status: 408) }
    if http.statusCode == 304 { return .notModified }
    guard (200..<300).contains(http.statusCode) else {
      throw IngestError(status: http.statusCode)
    }

    guard let body = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
      let version = body["version"] as? Int, version >= 0,
      let skan = body["skan"] as? [String: Any]
    else { throw IngestError(status: 422) }

    return .fetched(
      RemoteSkanConfig(
        version: version,
        rules: try decodeRules(skan),
        etag: http.value(forHTTPHeaderField: "etag")))
  }

  /// Decoded by hand rather than through Codable: the server's shape is a JSON
  /// object the dashboard writes, and a decoding failure must be an ordinary
  /// rejected config rather than an exception nobody catches.
  private func decodeRules(_ raw: [String: Any]) throws -> ConversionValueConfig {
    let rawRules = raw["rules"] as? [[String: Any]] ?? []
    let rules: [ConversionValueRule] = rawRules.compactMap { rule in
      guard let fine = rule["fineValue"] as? Int else { return nil }
      return ConversionValueRule(
        fineValue: fine,
        coarseValue: (rule["coarseValue"] as? String).flatMap(CoarseValue.init(rawValue:)),
        minRevenueMicros: rule["minRevenueMicros"] as? String,
        events: rule["events"] as? [String])
    }
    guard rules.count == rawRules.count else { throw IngestError(status: 422) }

    return ConversionValueConfig(
      rules: rules,
      defaultCoarse: (raw["defaultCoarse"] as? String).flatMap(CoarseValue.init(rawValue:)),
      revenueCurrency: raw["revenueCurrency"] as? String)
  }
}

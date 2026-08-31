import Foundation

/// The conversion-value config as the server serves it, with the version the
/// server uses to tell which config produced a reported value.
public struct RemoteSkanConfig: Equatable, Sendable {
  public let version: Int
  public let rules: ConversionValueConfig
  public let etag: String?

  public init(version: Int, rules: ConversionValueConfig, etag: String? = nil) {
    self.version = version
    self.rules = rules
    self.etag = etag
  }
}

public enum SkanConfigResult: Sendable {
  case fetched(RemoteSkanConfig)
  /// The server answered 304: whatever is cached is still current.
  case notModified
}

public protocol SkanConfigSource: Sendable {
  func fetch(etag: String?) async throws -> SkanConfigResult
}

public let SKAN_CONFIG_KEY = "advenue.skan.config"

/// Decides which config to use, given what the server said and what is cached.
///
/// The rules are about staying measurable rather than staying current:
///
/// - A **304** or a **failure** keeps the cached config. A device on a flaky
///   network must not lose SKAN entirely; a config from last week measures far
///   more than no config at all.
/// - A fetched config that does **not validate** is refused and the cache kept.
///   A bad config pushed to production would otherwise brick measurement on
///   every device at once, which is the failure mode a remote config exists to
///   avoid rather than create.
/// - Only when there is no cache and no valid fetch does the app-supplied
///   config apply, which is why it stays in `AdvenueConfig` as an offline
///   default rather than being removed.
public func chooseSkanConfig(
  fetched: SkanConfigResult?,
  cached: RemoteSkanConfig?,
  fallback: ConversionValueConfig?
) -> RemoteSkanConfig? {
  if case .fetched(let remote) = fetched, (try? ConversionValueMapper(remote.rules)) != nil {
    return remote
  }
  if let cached { return cached }
  guard let fallback, (try? ConversionValueMapper(fallback)) != nil else { return nil }
  // Version 0 marks "not from the server", which is what the server reads it as.
  return RemoteSkanConfig(version: 0, rules: fallback)
}


extension RemoteSkanConfig: Codable {
  private enum CodingKeys: String, CodingKey { case version, rules, etag }
}

/// Reads and writes the cached config. Persisted so a launch with no network
/// still measures — the alternative is that every offline cold start silently
/// stops reporting conversion values.
public enum SkanConfigCache {
  public static func load(_ store: KeyValueStore) -> RemoteSkanConfig? {
    guard let raw = store.string(forKey: SKAN_CONFIG_KEY), let data = raw.data(using: .utf8)
    else { return nil }
    return try? JSONDecoder().decode(RemoteSkanConfig.self, from: data)
  }

  public static func save(_ config: RemoteSkanConfig, to store: KeyValueStore) {
    guard let data = try? EventEncoding.canonicalEncoder().encode(config) else { return }
    store.set(String(decoding: data, as: UTF8.self), forKey: SKAN_CONFIG_KEY)
  }
}

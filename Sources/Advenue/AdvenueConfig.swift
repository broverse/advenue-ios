import AdvenueCore
import AdvenuePlatform
import Foundation

public struct AdvenueConfig: Sendable {
  public var apiKey: String
  public var endpoint: String
  public var appVersion: String?
  public var requireConsent: Bool
  public var sessionWindowMs: Int64

  /// Per-key HMAC secret. **Read this before setting it.** The signature
  /// provides integrity and replay protection, not authentication: anything
  /// shipped inside an app binary can be extracted from it, exactly as it can
  /// from a JavaScript bundle. Leaving it nil sends unsigned requests, which
  /// the server accepts unless the app enforces signatures.
  public var signingSecret: String?

  /// Called when the SDK swallows a best-effort failure. Never receives PII.
  public var onError: @Sendable (String, any Error) -> Void

  public init(
    apiKey: String,
    endpoint: String = DEFAULT_ENDPOINT,
    appVersion: String? = nil,
    requireConsent: Bool = false,
    sessionWindowMs: Int64 = DEFAULT_SESSION_WINDOW_MS,
    signingSecret: String? = nil,
    onError: @escaping @Sendable (String, any Error) -> Void = { _, _ in }
  ) {
    self.apiKey = apiKey
    self.endpoint = endpoint
    self.appVersion = appVersion
    self.requireConsent = requireConsent
    self.sessionWindowMs = sessionWindowMs
    self.signingSecret = signingSecret
    self.onError = onError
  }
}

/// Stamped on every event as `sdkVersion`. Swift has no runtime access to its
/// package version, so this is a constant — and a constant drifts from the
/// release tag unless something checks. CI does, because the first question
/// every field report raises is which build produced the event.
public enum AdvenueVersion {
  public static let current = "0.1.0"
}

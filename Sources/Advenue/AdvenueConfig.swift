import AdvenueCore
import AdvenuePlatform
import Foundation

public struct AdvenueConfig: Sendable {
  public var apiKey: String
  public var endpoint: String
  /// Ignored: the SDK reads the app version from the bundle itself. Setting it
  /// reports `config.ignored:appVersion` through `onError`. Removed in the next major.
  public var appVersion: String?
  public var requireConsent: Bool
  public var sessionWindowMs: Int64
  /// Events per request. Matches the other SDKs.
  public var batchSize: Int
  /// Auto-flush period. Zero disables the timer, which is what tests want and
  /// no shipping app does.
  public var flushIntervalMs: Int

  /// Per-key HMAC secret. **Read this before setting it.** The signature
  /// provides integrity and replay protection, not authentication: anything
  /// shipped inside an app binary can be extracted from it, exactly as it can
  /// from a JavaScript bundle. Leaving it nil sends unsigned requests, which
  /// the server accepts unless the app enforces signatures.
  public var signingSecret: String?

  /// SKAdNetwork conversion values. Absent means SKAN is not armed at all —
  /// there is nothing to report without rules, so the machine is not built
  /// rather than built and idle.
  public var conversionValues: ConversionValueConfig?

  /// Called when the SDK swallows a best-effort failure. Never receives PII.
  public var onError: @Sendable (String, any Error) -> Void

  /// Development aid: logs the SDK's start, every failure `onError` sees and
  /// each accepted batch to the unified log (subsystem `io.advenue.sdk`) —
  /// Xcode's console and Console.app. Never logs an identifier or a payload.
  /// Leave off in production; route failures through `onError` instead.
  public var debug: Bool

  /// B1: track/install properties PII scrub. On by default; disable only
  /// explicitly (documented risk — raw PII reaches ingest). Same as Android.
  public var piiScrubEnabled: Bool

  /// Overrides the version stamped on every event. Set by a WRAPPER SDK, never
  /// by an app.
  ///
  /// An event stamped with the Swift SDK's own version says the same thing for
  /// every install and answers nothing. The useful answer is which wrapper
  /// produced it — a React Native or Flutter release pins the native snapshot
  /// inside it, so the wrapper's version identifies both, and wrapper-specific
  /// bugs are the ones that need identifying. Adjust and AppsFlyer report the
  /// wrapper for the same reason.
  ///
  /// Capped at 32 characters by the ingest schema; a longer value would take
  /// the whole batch down with a 400, so it is truncated rather than sent.
  public var sdkVersion: String?

  /// B5: `https://` şema kuralı. Fail-fast `precondition` ile kurulumda
  /// yakalanır; kuralın kendisi test edilebilir saf fonksiyondur.
  public static func isSecureEndpoint(_ endpoint: String) -> Bool {
    endpoint.lowercased().hasPrefix("https://")
  }

  public init(
    apiKey: String,
    endpoint: String = DEFAULT_ENDPOINT,
    appVersion: String? = nil,
    requireConsent: Bool = false,
    sessionWindowMs: Int64 = DEFAULT_SESSION_WINDOW_MS,
    batchSize: Int = 20,
    flushIntervalMs: Int = 15_000,
    signingSecret: String? = nil,
    conversionValues: ConversionValueConfig? = nil,
    onError: @escaping @Sendable (String, any Error) -> Void = { _, _ in },
    sdkVersion: String? = nil,
    allowInsecureHttp: Bool = false,
    debug: Bool = false,
    piiScrubEnabled: Bool = true
  ) {
    precondition(
      allowInsecureHttp || Self.isSecureEndpoint(endpoint),
      "Advenue endpoint must use https:// (allowInsecureHttp is test-only)")
    self.apiKey = apiKey
    self.endpoint = endpoint
    self.appVersion = appVersion
    self.requireConsent = requireConsent
    self.debug = debug
    self.sessionWindowMs = sessionWindowMs
    self.batchSize = batchSize
    self.flushIntervalMs = flushIntervalMs
    self.signingSecret = signingSecret
    self.conversionValues = conversionValues
    self.onError = onError
    self.sdkVersion = sdkVersion
    self.piiScrubEnabled = piiScrubEnabled
  }
}

/// Stamped on every event as `sdkVersion`. Swift has no runtime access to its
/// package version, so this is a constant — and a constant drifts from the
/// release tag unless something checks. CI does, because the first question
/// every field report raises is which build produced the event.
public enum AdvenueVersion {
  public static let current = "1.1.0"
}

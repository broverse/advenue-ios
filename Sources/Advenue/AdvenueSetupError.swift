/// A condition met while starting the SDK, reported through `onError` under
/// the context in parentheses. Not a transport failure — these used to arrive
/// as `IngestError(status: 0)`, which read as an HTTP error that never
/// happened and named no cause.
public enum AdvenueSetupError: Error, Equatable, Sendable, CustomStringConvertible {
  /// `config.ignored:appVersion`
  case appVersionIgnored
  /// `store.cache_unavailable`
  case cacheUnavailable
  /// `identity.deferred`
  case identityDeferred

  public var description: String {
    switch self {
    case .appVersionIgnored:
      return "appVersion is read from the bundle; the config value has no effect"
    case .cacheUnavailable:
      return "the Caches directory is unavailable; the event queue falls back to UserDefaults"
    case .identityDeferred:
      return "the Keychain is unavailable (not unlocked since boot, or the app is not "
        + "code-signed); nothing starts until the next launch that can read it"
    }
  }
}

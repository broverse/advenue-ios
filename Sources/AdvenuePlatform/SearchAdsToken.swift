import Foundation

#if canImport(AdServices)
  import AdServices
#endif

public enum SearchAdsError: Error, Sendable {
  /// Retrying may succeed — the token is often unavailable for a few seconds
  /// after install.
  case transient
  /// Retrying cannot help.
  case unsupported
}

/// Fetches the Apple Search Ads attribution token, retrying transient
/// failures.
///
/// `AAAttribution.attributionToken()` can fail immediately after install;
/// field reports put the transient internal error at roughly 8% of users. The
/// RN module calls it once and rejects on any throw, so those installs
/// silently become organic and Apple Search Ads spend goes unattributed.
///
/// The retry deliberately outlives the caller's first-open deadline: the
/// install is never held for it, and a token obtained on a later attempt
/// travels on the next event. Holding the install instead would shift
/// attribution windows, which is worse than a less enriched install.
public struct SearchAdsTokenFetcher: Sendable {
  private let attempts: Int
  private let delayMs: Int
  private let fetch: @Sendable () throws -> String

  public init(
    attempts: Int = 3,
    delayMs: Int = 1000,
    fetch: (@Sendable () throws -> String)? = nil
  ) {
    self.attempts = attempts
    self.delayMs = delayMs
    self.fetch = fetch ?? Self.systemFetch
  }

  @Sendable
  private static func systemFetch() throws -> String {
    #if canImport(AdServices)
      if #available(iOS 14.3, *) {
        do {
          return try AAAttribution.attributionToken()
        } catch {
          throw SearchAdsError.transient
        }
      }
      throw SearchAdsError.unsupported
    #else
      throw SearchAdsError.unsupported
    #endif
  }

  public func token() async -> String? {
    for attempt in 1...attempts {
      do {
        return try fetch()
      } catch SearchAdsError.unsupported {
        return nil
      } catch {
        guard attempt < attempts else { return nil }
        // 1 s, 2 s, 4 s — long enough for the system to settle, bounded so a
        // permanently broken device does not retry forever.
        let backoff = delayMs * (1 << (attempt - 1))
        if backoff > 0 {
          try? await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000)
        }
      }
    }
    return nil
  }
}

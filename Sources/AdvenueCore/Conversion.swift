import Foundation

/// Deferred deep linking: the install that came from a link carrying a
/// destination, where the destination has to survive the trip through the App
/// Store.
///
/// The device asks the server what it was attributed to. An organic install is
/// never attributed, so the lookup is *expected* to answer pending forever for
/// most devices — which is why the loop gives up rather than polling on.
public struct DeepLink: Equatable, Sendable {
  public var deepLinkValue: String?
  public var campaign: String?
  public var network: String?
  public var influencerId: String?
  public var isDeferred: Bool
  public var isFirstLaunch: Bool

  public init(
    deepLinkValue: String? = nil, campaign: String? = nil, network: String? = nil,
    influencerId: String? = nil, isDeferred: Bool = true, isFirstLaunch: Bool = true
  ) {
    self.deepLinkValue = deepLinkValue
    self.campaign = campaign
    self.network = network
    self.influencerId = influencerId
    self.isDeferred = isDeferred
    self.isFirstLaunch = isFirstLaunch
  }
}

/// What a lookup returned: still deciding, or decided.
public enum ConversionResult: Equatable, Sendable {
  case pending
  case resolved(DeepLink)
}

public protocol ConversionFetcher: Sendable {
  /// Throws `IngestError` on a non-2xx; `isRetryable` decides what happens next.
  func fetch() async throws -> ConversionResult
}

/// Copied from `packages/sdk-core/src/conversion.ts`, not chosen here.
public let DEFAULT_CONVERSION_BACKOFF_MS: [Int] = [500, 1000, 2000, 4000]

/// Polls the conversion lookup until it resolves, the budget runs out, or the
/// server says never.
///
/// The three exits are deliberately different. A **pending** answer means the
/// pipeline has not decided yet, so it is worth waiting. A **non-retryable**
/// error is the server saying it never will, and retrying is pure battery cost
/// on a device that will never get an answer. A **transient** error is
/// indistinguishable from pending, so it falls through to the same backoff.
public func resolveDeferredDeepLink(
  fetcher: any ConversionFetcher,
  maxAttempts: Int = 5,
  backoffMs: [Int] = DEFAULT_CONVERSION_BACKOFF_MS,
  sleep: @Sendable (Int) async -> Void = { ms in
    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
  }
) async -> DeepLink? {
  for attempt in 0..<maxAttempts {
    do {
      if case .resolved(let link) = try await fetcher.fetch() { return link }
    } catch {
      if let ingest = error as? IngestError, !ingest.isRetryable { return nil }
      // Retryable, or a transport failure: fall through to the backoff.
    }

    if attempt < maxAttempts - 1 {
      await sleep(attempt < backoffMs.count ? backoffMs[attempt] : (backoffMs.last ?? 0))
    }
  }
  return nil
}

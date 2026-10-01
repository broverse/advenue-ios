import Foundation

/// A non-2xx ingest response. `isRetryable` separates a transient failure from
/// a poison payload: retrying a 400 forever would block the queue head, and
/// dropping a 429 would discard events over a throttle.
public struct IngestError: Error, Equatable, Sendable, CustomStringConvertible {
  public let status: Int
  /// Set when no response arrived at all — DNS, refused connection, timeout,
  /// no network. `status` is then 408 so the backoff retries it, but that 408
  /// was never sent by a server, and logging it as one sends whoever debugs it
  /// looking at the wrong end (F-SDK-10).
  public let networkCause: String?

  public init(status: Int, networkCause: String? = nil) {
    self.status = status
    self.networkCause = networkCause
  }

  public var description: String {
    if let networkCause { return "IngestError: no response (network error: \(networkCause))" }
    return "IngestError(status: \(status))"
  }

  public var isRetryable: Bool {
    status == 408 || status == 429 || status >= 500
  }
}

/// The delay armed after the Nth consecutive transient failure.
///
/// Mirrors sdk-core's `armBackoff`: the cap applies to the exponential term
/// BEFORE the jitter is added, so the true maximum is `capMs * 1.2`, not
/// `capMs`. `random` is injected so the schedule is a pure function.
public func backoffDelayMs(
  failures: Int,
  baseMs: Double,
  capMs: Double,
  random: Double
) -> Double {
  let exponential = min(baseMs * pow(2, Double(failures - 1)), capMs)
  return exponential + exponential * 0.2 * random
}

import Foundation

/// Upper bound for `AdvenueConfig.attConsentWaitingInterval`, in seconds.
/// Adjust parity (their v4 cap): a longer hold keeps the install — and every
/// flush behind it — hostage to a prompt the app may never show.
public let ATT_CONSENT_WAIT_MAX_SEC = 120
/// How often the wait re-reads the ATT status. A synchronous getter, so one
/// round costs nothing next to the seconds being waited out.
public let ATT_WAIT_POLL_MS = 500

/// Waits until the ATT status leaves `notDetermined`, or the timeout lapses.
///
/// There is no OS callback for "the user answered elsewhere" — the only
/// signal is polling `trackingAuthorizationStatus`, which is what Adjust does
/// too. Both the reader and the sleep are injected so the deadline behaviour
/// is testable without ATT, which no simulator can exercise.
///
/// Returns the resolved status, or `.notDetermined` on timeout. On
/// cancellation returns the live reading: a shut-down SDK must not finish
/// someone else's wait, but it reports what it saw. Never prompts — showing
/// the dialog is the app's decision, and this also runs on paths (a
/// background launch) where prompting is impossible.
public func waitForAttDetermination(
  status: @Sendable () -> TrackingAuthorization,
  pollMs: Int,
  timeoutMs: Int,
  sleep: @Sendable (Int) async -> Void
) async -> TrackingAuthorization {
  let step = max(pollMs, 1)
  var waited = 0
  while true {
    if Task.isCancelled { return status() }
    let current = status()
    if current != .notDetermined { return current }
    if waited >= timeoutMs { return .notDetermined }
    await sleep(step)
    waited += step
  }
}

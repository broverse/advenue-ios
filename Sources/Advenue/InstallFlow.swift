import AdvenueCore
import AdvenuePlatform
import Foundation

/// Flush hold for a launch that still owes its install: the ATT wait, then
/// the enrichment window and its scheduling margin. With no wait this is
/// exactly the old constant.
func installHoldMs(attWaitSec: Int) -> Int {
  attWaitSec * 1000 + INSTALL_WINDOW_MS + INSTALL_HOLD_MARGIN_MS
}

/// The install flow as a seam: submit, sources, the ATT status reader and the
/// sleep are parameters, so the wait ordering is testable without Keychain,
/// ATT or the network. Production wires the facade's pipe, the system
/// sources, `AdvertisingIdentity.status` and `Task.sleep`.
///
/// The wait runs only while the install is still owed and the status is
/// `notDetermined`. Enrichment runs after it — its IDFA read sees the
/// post-wait value, which is the entire point. On cancellation (a second
/// `initialize` replacing this one) nothing is submitted.
func runInstallFlow(
  submit: @escaping @Sendable (Command) -> Void,
  sources: EnrichmentSources,
  attStatus: @escaping @Sendable () -> TrackingAuthorization,
  attWaitMs: Int,
  installOwed: Bool,
  deviceInfo: @escaping @Sendable () -> [String: AdvenueValue],
  tcf: @escaping @Sendable () -> Consent?,
  deadlineMs: Int,
  sleep: @escaping @Sendable (Int) async -> Void,
  log: @escaping @Sendable (String) -> Void
) async {
  var waited = false
  if installOwed, attWaitMs > 0, attStatus() == .notDetermined {
    log("[Advenue] waiting up to \(attWaitMs / 1000)s for the ATT answer before the install")
    let resolved = await waitForAttDetermination(
      status: attStatus, pollMs: ATT_WAIT_POLL_MS, timeoutMs: attWaitMs, sleep: sleep)
    log("[Advenue] ATT wait ended: \(resolved.rawValue)")
    waited = true
  }
  guard !Task.isCancelled else { return }
  // The hold was sized from launch; after a wait the app may have spent
  // suspended, it can already have lapsed. Enrichment still has to run.
  if waited { submit(.extendInstallHold(holdMs: deadlineMs + INSTALL_HOLD_MARGIN_MS)) }
  let enrichment = await collectEnrichment(sources, deadlineMs: deadlineMs)
  guard !Task.isCancelled else { return }
  submit(
    .setIdentity(
      idfa: enrichment.idfa, vendorId: enrichment.vendorId,
      appInstanceId: enrichment.appInstanceId,
      limitAdTracking: enrichment.limitAdTracking))
  submit(.setDeviceInfo(deviceInfo()))
  // The CMP writes TCF to the standard defaults, and reading it is the
  // difference between shipping a real consent signal and shipping none.
  // Submitted before the install so the first event carries it.
  if let consent = tcf() { submit(.setConsentData(consent)) }
  submit(
    .trackInstall(
      adservicesToken: enrichment.adservicesToken,
      attestation: enrichment.attestation,
      attestationChallenge: enrichment.attestationChallenge))
  submit(.flush)
}

# Advenue iOS SDK (Swift)

The version is `AdvenueVersion.current` and the podspec's `s.version`; both are
stamped on every event as `sdkVersion`. Release tags are `sdk-swift-v<version>`.

## 1.2.1

- **No `main.sync` on every flush.** The identity refresh read the vendor id
  through `DispatchQueue.main.sync` from the flush timer's queue (and React
  Native's JS thread), which deadlocks whenever main is itself waiting on that
  thread. It now reads the vendor id only when already on main and otherwise
  keeps the last one seen; the IDFA and ATT status are still read every time.
- **The ATT wait ends on the wall clock.** It counted slept polls, so an app
  suspended mid-wait stretched it well past the interval while the install
  hold — wall clock — had lapsed, letting the launch's events go out ahead of
  the install. The wait is now bounded by both, and re-arms the hold for
  enrichment once it ends.
- Docs: the wait helps a prompt shown soon after launch, not one behind a
  long onboarding — the 120 s cap runs out first.

## 1.2.0

- **ATT wait (`attConsentWaitingInterval`).** Opt-in seconds to wait for the
  ATT answer before the install is enriched and sent (Adjust parity, capped at
  120 s, clamped values reported as `config.clamped:attConsentWaitingInterval`).
  Default 0 preserves today's behaviour. Set it when the app prompts after
  onboarding — otherwise the install ships IDFA-less and matches
  probabilistically. Only enable it if the app actually prompts. The install
  timestamp stays at launch time, so the wait delays visibility, never the
  attribution window.
- **IDFA re-read after the prompt.** `requestTrackingAuthorization()` hands the
  resolved identity back to the core; before, a granted permission reached no
  event.
- **Identity refresh on flush and foreground.** The advertising identity is
  re-read at send time (the MMP model), so apps that prompt through Apple's
  API directly — or users who flip tracking in Settings — are picked up on
  the next event. Never touches the App Instance ID.

## 1.1.1

- **Swift 6 main-actor reads.** `UIScreen.main`, `UIDevice.current` and
  `UIApplication.applicationState` are main-actor isolated under Swift 6. The
  device and advertising-identity collectors run on background tasks, so they
  now hop to the main queue for those reads instead of touching UIKit off the
  main thread. No public API changes.

## 1.1.0

- **Batch `sentAt`.** Every upload attempt stamps the batch with the time it
  was sent (re-stamped on each retry), so the server can correct device clock
  skew. Covered by a conformance vector shared with Android.
- **Install first.** A launch that still owes its install marks it before the
  foreground. The install carries that time, goes to the head of the queue,
  and flushes are held until it is enqueued (bounded by the enrichment
  deadline + 2 s). Before, iOS stamped the install only after ATT, AdServices
  and attestation finished, so a `session_start` and custom events could reach
  the server ahead of it.
- **Kill recovery.** A relaunch after the OS killed the app no longer splits
  the session. The session state keeps a heartbeat refreshed on every event
  and flush tick (Adjust's `lastActivity` model). The orphaned sub-session is
  closed at that time; the relaunch is a sub-session inside the session
  window, or a new session after it. Activity the relaunched process tracks
  before its foreground no longer counts the dead time as active.
- **Deferred deep links with a project key.** The conversion lookup sends
  `?platform=ios` on `/sdk/conversion-data`, so a project API key resolves the
  right listing (it answered `403 scope_unsupported` before).
- Setup conditions (a locked Keychain, an unsigned build, an unavailable
  cache, an ignored `appVersion`) reach `onError` as an `AdvenueSetupError`
  that says what happened, instead of `IngestError(status: 0)`.
- A request with no response is logged as a network error, not as HTTP 408.
  It is still retried exactly as before.

## 1.0.0

- Stable public API. Session fixes: a process woken into the background opens
  no session; `notifyForeground()` / `notifyBackground()` go through the
  lifecycle tracker. `debug` logging and the test-only `allowInsecureHttp`.

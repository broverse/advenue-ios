# Advenue iOS SDK (Swift)

The version is `AdvenueVersion.current` and the podspec's `s.version`; both are
stamped on every event as `sdkVersion`. Release tags are `sdk-swift-v<version>`.

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

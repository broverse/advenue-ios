import AdvenueCore
import AdvenuePlatform
import Foundation

#if canImport(UIKit)
  import UIKit
#endif

/// The public SDK. A static facade matching the React Native SDK's names, so a
/// developer moving to native reads the same API, delegating to state that is
/// replaceable and inspectable rather than to a hidden singleton.
public enum Advenue {
  private static let state = FacadeState()

  /// Starts the SDK. Safe to call from `didFinishLaunchingWithOptions`, and
  /// safe to call twice: the previous instance is shut down first. Without
  /// that, a second call leaves two consumer tasks draining one stream and
  /// duplicate lifecycle observers, so events are processed twice or lost.
  public static func initialize(_ config: AdvenueConfig) {
    state.start(config)
  }

  /// Records an event. Synchronous, non-blocking and ordered.
  public static func track(_ name: String, properties: [String: AdvenueValue]? = nil) {
    state.submit(.track(name: name, properties: properties, type: "custom"))
    // SKAN sees app events, never the SDK's own. An `adv_`-prefixed signal —
    // adv_meta_aem, adv_skan_update — satisfying a conversion rule would move
    // an advertiser's conversion value on the SDK's behalf.
    if !name.hasPrefix("adv_") {
      state.submit(.recordSkan(event: name, revenueMicros: nil, revenueCurrency: nil))
    }
  }

  /// Reports revenue to SKAdNetwork, in canonical micros. A string rather than
  /// a number because money must not go through a Double.
  public static func recordSkanRevenue(micros: String, currency: String) {
    state.submit(.recordSkan(event: nil, revenueMicros: micros, revenueCurrency: currency))
  }

  /// Reports revenue as the decimal amount a StoreKit price is quoted in
  /// ("9.99"), converted to exact micros here. Returns false — recording
  /// nothing — for an amount that is not a non-negative decimal with at most
  /// six places; coercing a malformed one to zero would report a conversion
  /// value the purchase did not earn.
  @discardableResult
  public static func recordSkanRevenue(amount: String, currency: String) -> Bool {
    guard let micros = decimalToMicros(amount) else { return false }
    recordSkanRevenue(micros: micros, currency: currency)
    return true
  }

  public static func setUserId(_ id: String?) { state.submit(.setUserId(id)) }

  public static func setConsent(_ granted: Bool) {
    state.rememberConsent(granted)
    state.submit(.setConsent(granted))
  }

  /// Whether tracking consent is currently granted. Persisted, so this is the
  /// answer after a restart too — a caller that defaulted to false on every
  /// cold start would silently discard a preference the user gave.
  public static func trackingConsent() -> Bool { state.trackingConsent }

  /// The granular DMA consent last set, or nil if none has been.
  public static func consentData() -> Consent? { state.consentData }

  /// The Firebase App Instance ID, when the app resolves it itself rather than
  /// through `AdvenueFirebase`. Does not disturb the advertising identity.
  public static func setAppInstanceId(_ id: String?) {
    state.submit(.setAppInstanceId(id))
  }

  /// Granular ad-platform consent (Google DMA), forwarded by server-side
  /// postbacks as gdpr_applies / ad_user_data / ad_personalization / ad_storage.
  ///
  /// Leave a field nil when the user has not been asked: "not stated" is not
  /// "denied", and inventing false on their behalf records a refusal that never
  /// happened.
  public static func setConsentData(_ consent: Consent?) {
    state.rememberConsentData(consent)
    state.submit(.setConsentData(consent))
  }

  /// Registers the device's push token for uninstall measurement.
  ///
  /// Advenue never asks for the notification permission and never displays
  /// anything. Pass the token your push library already gives you, on every
  /// launch: the OS can rotate it, and a stale token is what makes uninstall
  /// measurement report churn that did not happen.
  ///
  /// Pass `provider: "fcm"` if this app holds an FCM token rather than an APNs
  /// one — probing an FCM token against APNs looks like an uninstall on every
  /// device.
  public static func setPushToken(_ token: String?, provider: String? = nil) {
    state.submit(.setPushToken(token: token, provider: provider))
  }

  /// The app the ingestion service resolved this API key to, or nil until a
  /// batch has been accepted.
  ///
  /// The API key is the SDK's entire app identity, so pasting the wrong one is
  /// silent: events are still accepted, just recorded against another app, and
  /// every screen the integrator checks is the one they believe they
  /// configured. This is the answer to "which app am I actually writing to",
  /// read from the device rather than inferred from the dashboard.
  public static func resolvedAppId() -> String? { state.resolvedAppId }

  /// Resolves the deferred deep link for this install, or nil for an organic
  /// one. Safe to call once on first launch; the app routes on the result.
  public static func resolveDeferredDeepLink() async -> DeepLink? {
    await state.fetchDeferredDeepLink()
  }

  /// Erasure. Spans both stores — see `FacadeState.forgetMe`. The SDK stops
  /// (an erased SDK records nothing) until the next `initialize`.
  public static func forgetMe() { state.forgetMe() }

  /// Sandbox only (spec 3 §7): makes this device a new install without
  /// reinstalling the app. Asks the server to clear the device's sandbox state,
  /// clears the queue, session, install flag and installation id, rotates the
  /// device id, and records a new install. Consent and the user id stay.
  /// Returns the new device id; in production it logs and returns nil.
  public static func resetInstall() async -> String? { await state.resetInstall() }

  /// The device identifier, or nil while identity is deferred.
  ///
  /// Async because resolution can be deferred while the Keychain is locked. A
  /// synchronous getter would have nothing to return there, and returning a
  /// guess is exactly the bug this SDK is built to avoid.
  public static func deviceId() async -> String? { state.currentDeviceId }

  /// Forward from `application(_:open:options:)`. Callable **before**
  /// `initialize`: a cold start from a link can run the app delegate first,
  /// and the links that carry attribution are precisely the ones that would
  /// be lost.
  public static func processDeepLink(_ url: URL) { state.deepLink(url) }

  /// Sends what is buffered. Safe to call at any time; a no-op when the queue
  /// is empty or a backoff window is open.
  public static func flush() { state.submit(.flush) }

  public static func notifyForeground() { state.notifyForeground() }

  /// Backgrounding both closes the session and flushes: a batch stranded at the
  /// moment the app leaves the foreground may not be sent for hours.
  public static func notifyBackground() { state.notifyBackground() }

  /// Presents the ATT prompt. The app decides when; the SDK never prompts on
  /// its own. After resolution the advertising identity is re-read and handed
  /// to the core — the prompt is the moment the IDFA appears (or
  /// limitAdTracking flips), and the install-time read predates it. Through
  /// the narrow setter: the App Instance ID is not the prompt's to clear.
  @discardableResult
  public static func requestTrackingAuthorization() async -> TrackingAuthorization {
    let status = await AdvertisingIdentity().requestAuthorization()
    let snapshot = AdvertisingIdentity().nonBlockingSnapshot()
    state.submit(
      .setAdvertisingIdentity(
        idfa: snapshot.idfa, vendorId: snapshot.vendorId,
        limitAdTracking: snapshot.limitAdTracking, attStatus: snapshot.attStatus?.rawValue))
    return status
  }

  /// Set by `AdvenueFirebase`; the base SDK knows only the shape, so
  /// FirebaseAnalytics is never forced on a consumer who does not use it.
  public static func setAppInstanceIdProvider(
    _ provider: @escaping @Sendable () async -> String?
  ) {
    state.setAppInstanceIdProvider(provider)
  }

  public static func shutdown() { state.stop() }
}

/// What `resetInstall()` logs, and all it does, outside the sandbox: a
/// production app must not mint "new" installs.
let RESET_INSTALL_PRODUCTION_LOG = "Advenue: resetInstall() works only in sandbox."
/// Sandbox, but stopped or with the device identity not yet resolved.
let RESET_INSTALL_NOT_RUNNING_LOG =
  "Advenue: resetInstall() needs a started SDK with a resolved device identity; nothing was reset."
/// A second call while one is in flight.
let RESET_INSTALL_BUSY_LOG = "Advenue: resetInstall() is already running; this call did nothing."

/// `resetInstall`'s restart: start only if the SDK is still at `expected`,
/// and give the device `mintedDeviceId`.
struct ResetPlan {
  let expected: Int
  let mintedDeviceId: String
}

/// An engine's uploads (K27): dropped, as if delivered, once `allowed` says an
/// erasure happened since the engine started.
struct FencedTransport: EventTransport {
  let inner: any EventTransport
  let allowed: @Sendable () -> Bool
  func send(_ events: [ClientEvent]) async throws {
    guard allowed() else { return }
    try await inner.send(events)
  }
}

/// The store an engine writes through (K27). Reads pass. A write of one of
/// the app's settings lands while `canWriteSettings` (no erasure since the
/// engine started); any other write lands while `canWriteBookkeeping` (the
/// engine still owns the store).
final class FencedStore: KeyValueStore, @unchecked Sendable {
  private static let settingKeys: Set<String> = [CONSENT_KEY, CONSENT_DATA_KEY, USER_ID_KEY]
  private let inner: any KeyValueStore
  private let canWriteSettings: @Sendable () -> Bool
  private let canWriteBookkeeping: @Sendable () -> Bool
  init(
    inner: any KeyValueStore, canWriteSettings: @escaping @Sendable () -> Bool,
    canWriteBookkeeping: @escaping @Sendable () -> Bool
  ) {
    self.inner = inner
    self.canWriteSettings = canWriteSettings
    self.canWriteBookkeeping = canWriteBookkeeping
  }
  func string(forKey key: String) -> String? { inner.string(forKey: key) }
  func set(_ value: String, forKey key: String) {
    if allowed(key) { inner.set(value, forKey: key) }
  }
  func removeObject(forKey key: String) {
    if allowed(key) { inner.removeObject(forKey: key) }
  }
  private func allowed(_ key: String) -> Bool {
    Self.settingKeys.contains(key) ? canWriteSettings() : canWriteBookkeeping()
  }
}

/// What `onError("resetInstall.server", …)` receives (K31): a description with
/// no identifier in it, and the original error for an app that wants it.
struct ResetServerError: Error, CustomStringConvertible {
  let description: String
  let underlying: any Error
}

/// A log sink made of a closure.
struct CallbackLogSink: AdvenueLogSink {
  let body: @Sendable (String) -> Void
  init(_ body: @escaping @Sendable (String) -> Void) { self.body = body }
  func log(_ message: String) { body(message) }
}

/// Thread-safe holder for the app the server reported. Diagnostics only.
final class AcceptedAppId: @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?

  var current: String? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  /// True the first time this app id is seen.
  @discardableResult
  func set(_ appId: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let changed = value != appId
    value = appId
    return changed
  }
}

/// Holds what a static facade cannot: the live engine, the command pipe, the
/// pre-init deep-link buffer and the resolved identity.
final class FacadeState: @unchecked Sendable {
  private let lock = NSLock()
  private var pipe: CommandPipe?
  private var secure: (any SecureStore)?
  private var store: (any KeyValueStore)?
  private var resolvedDeviceId: String?
  /// Set by the transport after a batch is accepted; diagnostics only.
  private let acceptedAppId = AcceptedAppId()
  private var startedConfig: AdvenueConfig?
  private var pendingDeepLinks: [URL] = []
  private var seenAemUrlHashes: Set<String> = []
  private var appInstanceIdProvider: (@Sendable () async -> String?)?
  private var flushTimer: DispatchSourceTimer?
  /// The install flow, retained so `stop()` can cancel it: with an ATT wait
  /// it can outlive the instance that started it by up to two minutes, and a
  /// wait that finishes into a replaced pipe submits to nobody — or worse.
  private var installTask: Task<Void, Never>?
  /// F7: the install's attestation, skipped because consent was withheld,
  /// armed to run on the pipe's next grant.
  private var attestationOnConsent:
    (attest: @Sendable () async -> (challenge: String, result: AttestationResult)?,
      pipe: CommandPipe)?
  /// Where the flush/foreground refresh reads the advertising identity.
  /// Production reads the system; tests script "the user answered between
  /// init and flush". Under the lock like everything else here.
  private var advertisingSource: @Sendable () -> AdvertisingSnapshot = {
    AdvertisingIdentity().nonBlockingSnapshot()
  }
  /// The last vendor id seen — from install enrichment or an on-main read.
  /// The refresh cannot read it off the main thread without blocking, and it
  /// does not change within a process, so a nil read reuses this rather than
  /// clearing the id on every event that follows.
  private var knownVendorId: String?
  /// Observers on the app's own lifecycle notifications, and the machine that
  /// decides what they mean. Held so `stop()` can remove them: a stale observer
  /// submitting into a finished pipe outlives the instance that made it.
  private var lifecycleObservers: [NSObjectProtocol] = []
  private var foreground = ForegroundTracker()
  /// Read caches for the two consent values. The engine owns persistence; these
  /// exist so a synchronous getter can answer without a round trip through the
  /// pipe, and so a caller reading back its own `setConsent` never sees the
  /// value it just replaced.
  private var consentMirror = false
  private var consentDataMirror: Consent?
  /// What `resetInstall` needs to start again exactly as the app did. Returns
  /// whether the plan was claimed (see `start`'s `resetPlan`).
  private var restart: ((ResetPlan) -> Bool)?
  private var requestedConfig: AdvenueConfig?
  private var deviceReset: (any SandboxDeviceResetting)?
  private var noticeSink: (any AdvenueLogSink)?
  /// Where `resetInstall` logs before any `start` has named a sink.
  private let fallbackSink: (any AdvenueLogSink)?
  /// True from the moment a `resetInstall` is accepted until it has restarted
  /// (or given up): a second call in that window is refused, not interleaved.
  private var resetting = false
  /// Moves on every `stop()` (and so every `start`). A reset that sees it move
  /// while it waited does not restart: someone else now owns the lifecycle.
  private var generation = 0
  /// F13: non-nil while a reset's drain has the pipe detached. setConsent,
  /// setConsentData and setUserId made in that window wait here and go onto
  /// the next pipe `start` builds (the restart, or a re-initialize); without
  /// it they would be dropped, and the restart would reseed the consent
  /// mirror from the store the drain began with.
  ///
  /// K2: at most one of each, kept in the order of their last write: only the
  /// final value of each setting matters, and a buffer that grows with every
  /// call is a leak with a long drain behind it.
  private var resetBuffer: [Command]?
  /// K25: moves on every forgetMe. A reset whose restart was claimed returns
  /// nil if an erasure landed after the claim.
  private var erasures = 0

  /// The lifecycle owner (K27). `start`, `stop`, `forgetMe`, a reset taking
  /// the pipe and a reset finishing (its restart and its settle) each run
  /// whole under this lock, one at a time, never nested. Invariants, by
  /// construction rather than by interleaving analysis:
  /// - the reset buffer is consumed by exactly one party: the next `start` to
  ///   install a pipe, or else the reset's settle (or `forgetMe`, which drops
  ///   it). Each disarms it in the same operation that reads it.
  /// - an erasure is applied by `forgetMe` itself, in full (stop, fence, wipe),
  ///   before any later lifecycle operation can resolve an identity.
  /// - no pipe is orphaned: a start cannot be superseded half-way.
  /// App callbacks raised inside an operation are delivered after it (see
  /// `deliver`), so a callback that calls back into the SDK cannot deadlock on
  /// this (non-reentrant) lock. Lock order: `lifecycle`, then `lock`.
  private let lifecycle = NSLock()
  /// Callbacks held until the current lifecycle operation ends. Under `lock`.
  private var heldCallbacks: [() -> Void]?
  /// The store fence (K27), two rules (see `FencedStore`):
  /// - the engine's own bookkeeping (queue, session, install flag, SKAN state)
  ///   is written only by the engine holding `storeOwner`, moved by every
  ///   `start` and `forgetMe`, so an engine still draining (or simply stopped)
  ///   never writes it behind a newer instance;
  /// - the app's settings (consent, consent data, user id) still land from an
  ///   older engine, since they are the app's latest word, unless an erasure
  ///   happened since that engine started (`erasures`).
  /// Under `lock`.
  private var storeOwner = 0
  /// Set by `forgetMe` until the next start installs a pipe: settings made in
  /// between go straight to the store, as the erased engine used to write them,
  /// and deep links are dropped, as it dropped them (FM1).
  private var erased = false
  /// Test surfaces: every pipe built, and every buffered setting applied.
  var onPipeCreated: ((CommandPipe) -> Void)?
  var onCarryApplied: ((Command) -> Void)?

  init(fallbackSink: (any AdvenueLogSink)? = nil) {
    self.fallbackSink = fallbackSink
  }

  /// `resetPlan` is `resetInstall`'s restart: start only if the generation is
  /// still the one the reset began on, and rotate the install identity in the
  /// same critical section. Returns false when it was not claimed (nothing was
  /// changed); every other start returns true.
  ///
  /// `transport` is a parameter, not a hidden construction, because an unwired
  /// transport is otherwise invisible: every component of the send path can be
  /// green while nothing joins them. `SeamTests` injects a recorder here.
  @discardableResult
  func start(
    _ config: AdvenueConfig,
    transport: (any EventTransport)? = nil,
    sources: EnrichmentSources? = nil,
    skan skanReporter: (any SkanReporter)? = nil,
    appVersion readVersion: @escaping () -> String? = readAppVersion,
    launchedInBackground: @escaping () -> Bool = readLaunchedInBackground,
    logSink: (any AdvenueLogSink)? = nil,
    advertisingSource: (@Sendable () -> AdvertisingSnapshot)? = nil,
    deviceReset: (any SandboxDeviceResetting)? = nil,
    secureStore: (any SecureStore)? = nil,
    resetPlan: ResetPlan? = nil
  ) -> Bool {
    lifecycleOperation {
      startLocked(
        config, transport: transport, sources: sources, skan: skanReporter,
        appVersion: readVersion, launchedInBackground: launchedInBackground, logSink: logSink,
        advertisingSource: advertisingSource, deviceReset: deviceReset,
        secureStore: secureStore, resetPlan: resetPlan)
    }
  }

  /// Runs `body` as one lifecycle operation (see `lifecycle`). Never called
  /// from inside one: the lock is not reentrant.
  private func lifecycleOperation<T>(_ body: () -> T) -> T {
    lifecycle.lock()
    lock.lock()
    heldCallbacks = []
    lock.unlock()
    let result = body()
    lock.lock()
    let held = heldCallbacks ?? []
    heldCallbacks = nil
    lock.unlock()
    lifecycle.unlock()
    for callback in held { callback() }
    return result
  }

  /// An app callback: now, or after the lifecycle operation in progress. Never
  /// called while holding `lock`.
  private func deliver(_ callback: @escaping () -> Void) {
    lock.lock()
    if heldCallbacks != nil {
      heldCallbacks?.append(callback)
      lock.unlock()
      return
    }
    lock.unlock()
    callback()
  }

  /// Whether `token` still owns the store (the fence). Asked by engines.
  private func ownsStore(_ token: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return storeOwner == token
  }

  private func noErasure(since epoch: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return erasures == epoch
  }

  /// `start`'s body. The caller holds `lifecycle`.
  private func startLocked(
    _ config: AdvenueConfig,
    transport: (any EventTransport)?,
    sources: EnrichmentSources?,
    skan skanReporter: (any SkanReporter)?,
    appVersion readVersion: @escaping () -> String?,
    launchedInBackground: @escaping () -> Bool,
    logSink: (any AdvenueLogSink)?,
    advertisingSource: (@Sendable () -> AdvertisingSnapshot)?,
    deviceReset: (any SandboxDeviceResetting)?,
    secureStore: (any SecureStore)?,
    resetPlan: ResetPlan?
  ) -> Bool {
    // `resetInstall` restarts with exactly these arguments, so a reset app
    // runs with the same transport, sources and sinks it was started with.
    let requestedConfig = config
    // Called by the reset's finish, inside its lifecycle operation.
    let restartArgs: (ResetPlan) -> Bool = { [weak self] plan in
      self?.startLocked(
        requestedConfig, transport: transport, sources: sources, skan: skanReporter,
        appVersion: readVersion, launchedInBackground: launchedInBackground, logSink: logSink,
        advertisingSource: advertisingSource, deviceReset: deviceReset,
        secureStore: secureStore, resetPlan: plan) ?? false
    }
    let secure: any SecureStore = secureStore ?? KeychainStore()

    // Replace-and-shut-down, never add: the same steps as `stop()`.
    lock.lock()
    if let plan = resetPlan {
      // K5: a reset's restart claims the SDK only if nothing moved the
      // generation while it drained; the lifecycle lock makes the claim, the
      // identity rotation and this start one operation.
      guard generation == plan.expected, let oldStore = self.store, let oldSecure = self.secure
      else {
        lock.unlock()
        return false
      }
      rotateInstallIdentity(
        store: oldStore, secure: oldSecure, mintedDeviceId: plan.mintedDeviceId)
      resolvedDeviceId = nil
    }
    generation += 1
    let replaced = detachLocked()
    // K23: nothing answers for the instance being replaced.
    resolvedDeviceId = nil
    startedConfig = nil
    // The fence: from here on only this start's engine writes the store.
    storeOwner += 1
    let storeToken = storeOwner
    let erasureEpoch = erasures
    // Recorded before the identity gate, so a reset on a deferred launch
    // still knows the environment it was asked for (and says so).
    self.restart = restartArgs
    self.requestedConfig = requestedConfig
    self.noticeSink = logSink
    self.deviceReset =
      deviceReset
      ?? HttpSandboxDeviceReset(
        endpoint: requestedConfig.endpoint, apiKey: requestedConfig.apiKey,
        signingSecret: requestedConfig.signingSecret)
    lock.unlock()
    replaced.cancel()
    replaced.pipe?.shutdown()

    // The app's own callbacks go through `deliver`: the ones raised while this
    // lifecycle operation runs reach the app after it.
    let appSink: any AdvenueLogSink = logSink ?? UnifiedLogSink()
    let deferredSink: any AdvenueLogSink = CallbackLogSink { [weak self] line in
      guard let self else { return appSink.log(line) }
      self.deliver { appSink.log(line) }
    }
    var deferredConfig = config
    let appOnError = config.onError
    deferredConfig.onError = { [weak self] context, error in
      guard let self else { return appOnError(context, error) }
      self.deliver { appOnError(context, error) }
    }

    // `debug`: every swallowed failure goes through onError, so logging there
    // covers all of them — wrapped once, before anything below captures it.
    let (debugConfig, log) = withDebugLogging(deferredConfig, sink: deferredSink)
    let config = withSandboxNotices(debugConfig, sink: deferredSink)

    // Clamped early and said so: a caller passing 600 must learn the wait is
    // 120. Before the Keychain gate, so it reports on every launch —
    // deferred or resolved, signed or not.
    let attWaitSec = AdvenueConfig.clampedAttWait(config.attConsentWaitingInterval)
    if attWaitSec != config.attConsentWaitingInterval {
      config.onError(
        "config.clamped:attConsentWaitingInterval", AdvenueSetupError.attWaitClamped)
    }

    // The SDK resolves the app version itself (readAppVersion); a config value
    // is ignored — and said so, rather than looking like it took effect.
    if config.appVersion != nil {
      config.onError("config.ignored:appVersion", AdvenueSetupError.appVersionIgnored)
    }

    // B4: kuyruk blob'u Caches dosyalarına (yedek dışı); UserDefaults'ta
    // kalan eski blob ilk okumada migrate edilir. Caches yoksa UserDefaults
    // geri dönüşüdür — yedek kapsamı açılır ama SDK çalışır (fail-open, loglanır).
    let store: any KeyValueStore
    if let files = CacheFileStore.caches() {
      store = CompositeStore(files: files)
    } else {
      store = UserDefaultsStore()
      config.onError("store.cache_unavailable", AdvenueSetupError.cacheUnavailable)
    }
    let scheduler = TimerScheduler()
    // Spec 2 §7.2: a changed environment starts clean — before the engine
    // loads the queue and before the install flag is read below.
    if let dropped = reconcileEnvironment(config.environment, store: store, scheduler: scheduler) {
      logEnvironmentChange(dropped: dropped, to: config.environment, log: log)
    }
    let uuid = SystemUUIDs()

    let identity = resolveIdentity(secure: secure, store: store, uuid: uuid)
    guard case .resolved(let deviceId, let installationId) = identity else {
      // Deferred: the Keychain could not be read. Nothing is minted and
      // nothing starts, so no event carries an invented identifier. The next
      // launch after first unlock resolves it.
      // A reset buffer stays armed: the reset's settle writes it to the store.
      config.onError("identity.deferred", AdvenueSetupError.identityDeferred)
      return true
    }

    let osVersion: String?
    #if canImport(UIKit)
      osVersion = onMainSync { UIDevice.current.systemVersion }
    #else
      osVersion = nil
    #endif

    let baseTransport =
      transport
      ?? HttpTransport(
        endpoint: config.endpoint, apiKey: config.apiKey,
        signingSecret: config.signingSecret,
        environment: config.environment,
        // Diagnostics only: it runs after the batch is already accepted, so
        // nothing it does can turn a successful ingest into a failure.
        onAccepted: { [acceptedAppId] appId in
          // A key pasted from the wrong app is otherwise silent.
          if acceptedAppId.set(appId) { log("[Advenue] ingesting into app \(appId)") }
        })
    // K27: nothing is uploaded behind an erasure, not even by an engine still
    // draining what it queued before.
    let eventTransport: any EventTransport = FencedTransport(
      inner: config.debug ? LoggingTransport(inner: baseTransport, log: log) : baseTransport,
      allowed: { [weak self] in self?.noErasure(since: erasureEpoch) ?? false })

    let engine = AdvenueEngine(
      config: EngineConfig(
        apiKey: config.apiKey, platform: "ios", deviceId: deviceId,
        installationId: installationId, appVersion: readVersion(),
        osVersion: osVersion,
        sdkVersion: String((config.sdkVersion ?? AdvenueVersion.current).prefix(32)),
        requireConsent: config.requireConsent, sessionWindowMs: config.sessionWindowMs,
        batchSize: config.batchSize, piiScrubEnabled: config.piiScrubEnabled,
        attStatus: AdvertisingIdentity().status.rawValue),
      store: FencedStore(
        inner: store,
        canWriteSettings: { [weak self] in self?.noErasure(since: erasureEpoch) ?? false },
        canWriteBookkeeping: { [weak self] in self?.ownsStore(storeToken) ?? false }),
      clock: SystemClock(), scheduler: scheduler, uuid: uuid,
      transport: eventTransport,
      onError: config.onError)
    let pipe = CommandPipe(engine: engine, onError: config.onError)
    lock.lock()
    let pipeObserver = onPipeCreated
    lock.unlock()
    pipeObserver?(pipe)

    // Armed only when there are rules to evaluate. The reporter is injectable
    // for the same reason the transport is: an unwired one is invisible, and
    // that shape has already cost this SDK three defects.
    // SKAN is armed from the config the SERVER serves, not from one baked into
    // the app: a conversion schema is tuned constantly and an app release cycle
    // is weeks, so a config that can only change by shipping a binary is a
    // config nobody changes. The app-supplied one stays as an offline default.
    //
    // The cached config arms SKAN synchronously through the ordered pipe, so an
    // event tracked immediately after initialize is measured. The network fetch
    // then re-arms if the server has something newer — a fetch raced against
    // those first events would silently drop them.
    let cached = SkanConfigCache.load(store)
    let reporter = skanReporter ?? StoreKitSkanReporter(onError: config.onError)

    if let initial = chooseSkanConfig(
      fetched: nil, cached: cached, fallback: config.conversionValues),
      let mapper = try? ConversionValueMapper(initial.rules)
    {
      pipe.submit(
        .enableSkan(
          mapper: mapper, currency: initial.rules.revenueCurrency,
          installationId: installationId, reporter: reporter,
          configVersion: initial.version))
    }

    if skanReporter == nil {
      let fetcher = HttpSkanConfigFetcher(endpoint: config.endpoint, apiKey: config.apiKey)
      Task {
        let fetched = try? await fetcher.fetch(etag: cached?.etag)
        guard let chosen = chooseSkanConfig(
          fetched: fetched, cached: cached, fallback: config.conversionValues),
          chosen.version != cached?.version || cached == nil,
          let mapper = try? ConversionValueMapper(chosen.rules)
        else { return }
        SkanConfigCache.save(chosen, to: store)
        pipe.submit(
          .enableSkan(
            mapper: mapper, currency: chosen.rules.revenueCurrency,
            installationId: installationId, reporter: reporter,
            configVersion: chosen.version))
      }
    }

    lock.lock()
    self.store = store
    self.secure = secure
    if let advertisingSource { self.advertisingSource = advertisingSource }
    // Seeded from the same persisted values the engine loads, so consent
    // granted in a previous run is still granted after a cold start.
    self.consentMirror = store.string(forKey: CONSENT_KEY) == "granted"
    self.consentDataMirror = readPersistedConsentData(store)
    self.pipe = pipe
    self.startedConfig = config
    // F13: what the app set while a reset drained goes onto this pipe, in
    // order, ahead of the install, reflected in the getters the store just
    // reseeded. Read and disarmed here, inside this lifecycle operation, so it
    // is applied exactly once.
    erased = false
    let carried = resetBuffer ?? []
    resetBuffer = nil
    for command in carried { applySettingLocked(command, pipe: pipe) }
    self.resolvedDeviceId = deviceId
    let buffered = pendingDeepLinks
    pendingDeepLinks = []
    lock.unlock()

    // Before anything else is recorded: a launch that still owes its install
    // stamps it now and holds every flush until the install is enqueued, so
    // the server never sees this launch's session or events ahead of it. The
    // hold covers the ATT wait plus the enrichment deadline and its margin,
    // then lapses.
    pipe.submit(.beginInstall(holdMs: installHoldMs(attWaitSec: attWaitSec)))

    // Replayed in arrival order, before the first session, so a deferred deep
    // link is attributed to the launch it belongs to.
    for url in buffered { deepLink(url) }
    // A launch into the background (fetch, silent push, location) is not a
    // session: the first didBecomeActive opens it instead. iOS posts no
    // didEnterBackground for an app that never left the background, so a
    // tracker seeded as foregrounded would swallow the user's real open.
    let inForeground = !launchedInBackground()
    if inForeground { pipe.submit(.foreground) }
    // Seeded to match: the line above IS this launch's foreground, so the
    // activation notification that follows must not open a second session.
    observeLifecycle(seededInForeground: inForeground)

    log(
      "[Advenue] initialized — endpoint \(config.endpoint), "
        + "sdk \(config.sdkVersion ?? AdvenueVersion.current), "
        // Not "background launch": a scene-based (SwiftUI) app is still
        // reported in the background during didFinishLaunching even when the
        // user opened it. Either way the session opens on activation.
        + (inForeground ? "launched active" : "not active yet, the session opens on activation"))

    if config.flushIntervalMs > 0 {
      let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
      timer.schedule(
        deadline: .now() + .milliseconds(config.flushIntervalMs),
        repeating: .milliseconds(config.flushIntervalMs))
      timer.setEventHandler { [weak self] in self?.submit(.flush) }
      timer.resume()
      lock.lock()
      flushTimer = timer
      lock.unlock()
    }

    // Enrichment, then the install, off the caller's thread. `initialize`
    // returns synchronously — an SDK that blocks
    // didFinishLaunchingWithOptions for three seconds is one nobody ships.
    let installSourcesUngated =
      sources
      ?? EnrichmentSources.system(
        appInstanceIdProvider: currentAppInstanceIdProvider,
        attestation: {
          // Two round trips, both best-effort: a device that cannot attest, a
          // challenge the server would not issue, or an attestKey failure all
          // yield nil and the install ships without the fields. An install held
          // for attestation is an install lost.
          let attestor = DeviceCheckAttestation(secure: secure)
          let challenges = HttpChallengeFetcher(
            endpoint: config.endpoint, apiKey: config.apiKey)
          guard let challenge = try? await challenges.challenge(deviceId: deviceId),
            let result = try? await attestor.attest(challenge: challenge)
          else { return nil }
          return (challenge: challenge, result: result)
        })
    // F7 (spec D7): the attestation's challenge fetch carries the device id,
    // so under requireConsent it does not run before consent. Skipped, it is
    // armed to run when consent is granted, and the engine holds the install
    // for it (see `submit`).
    var installSources = installSourcesUngated
    if config.requireConsent {
      let attestNow = installSourcesUngated.attestation
      installSources.attestation = { [weak self] in
        guard let self else { return nil }
        if self.deferAttestationUntilConsent(attestNow, pipe: pipe) { return nil }
        return await attestNow()
      }
    }
    // Whether the wait runs at all is decided up front, from the same flag
    // the engine guards on: a launch that already sent its install never
    // waits, whatever the interval says.
    let installOwed = store.string(forKey: INSTALL_SENT_KEY) != "1"
    lock.lock()
    installTask?.cancel()
    installTask = Task { [weak self] in
      guard let self else { return }
      await runInstallFlow(
        submit: { [weak self] in self?.submit($0) },
        sources: installSources,
        attStatus: { AdvertisingIdentity().status },
        attWaitMs: attWaitSec * 1000,
        installOwed: installOwed,
        // Wrapped, not referenced: a bare function reference warns as a
        // non-Sendable conversion under the iOS check; the closure captures
        // nothing, so it is Sendable.
        deviceInfo: { collectDeviceInfo() },
        tcf: { readTcf() },
        deadlineMs: INSTALL_WINDOW_MS,
        sleep: { ms in try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) },
        log: log)
    }
    lock.unlock()
    return true
  }

  /// F7: whether the install's attestation must wait for consent. Decided
  /// against the consent mirror under `lock`, the same section `submit` takes
  /// the armed attestation in, so a grant racing this either sees it armed or
  /// is seen here as granted. Returns true when the attestation was skipped.
  private func deferAttestationUntilConsent(
    _ attest: @escaping @Sendable () async -> (challenge: String, result: AttestationResult)?,
    pipe: CommandPipe
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if consentMirror { return false }
    // A replaced pipe's install flow is cancelled; it attests nothing.
    guard self.pipe === pipe else { return true }
    attestationOnConsent = (attest, pipe)
    pipe.submit(.awaitInstallAttestation(holdMs: INSTALL_WINDOW_MS + INSTALL_HOLD_MARGIN_MS))
    return true
  }

  /// F7: runs the attestation consent held back and releases the deferred
  /// install with it, onto the pipe the install is waiting on. Bounded like
  /// enrichment: an install held for attestation is an install lost.
  private static func attestAfterConsent(
    _ attest: @escaping @Sendable () async -> (challenge: String, result: AttestationResult)?,
    pipe: CommandPipe
  ) {
    Task {
      let attested = await withDeadline(ms: INSTALL_WINDOW_MS, { await attest() }) ?? nil
      pipe.submit(
        .releaseDeferredInstall(
          attestation: attested?.result, attestationChallenge: attested?.challenge))
      pipe.submit(.flush)
    }
  }

  /// A carried setting, onto a live pipe and into the getters. Caller holds `lock`.
  private func applySettingLocked(_ command: Command, pipe: CommandPipe) {
    onCarryApplied?(command)
    switch command {
    case .setConsent(let granted): consentMirror = granted
    case .setConsentData(let consent): consentDataMirror = consent
    default: break
    }
    pipe.submit(command)
  }

  /// The erasure, written straight to the stores (no engine is left to run it).
  private static func eraseStored(store: any KeyValueStore, secure: any SecureStore) {
    for key in [
      CONSENT_KEY, CONSENT_DATA_KEY, SESSION_STATE_KEY, USER_ID_KEY, INSTALL_SENT_KEY,
      INSTALLATION_ID_KEY, QUEUE_KEY,
    ] {
      store.removeObject(forKey: key)
    }
    secure.delete(DEVICE_ID_KEY)
  }

  private var currentAppInstanceIdProvider: (@Sendable () async -> String?)? {
    lock.lock()
    defer { lock.unlock() }
    return appInstanceIdProvider
  }

  /// K15: the pipe is read and submitted to in ONE critical section, so a
  /// command cannot be read against the old pipe and land on it after a reset
  /// took it (behind `.resetInstall`, where the finished engine drops it).
  /// `pipe.submit` is a non-blocking yield. What goes onto the pipe is worked
  /// out first, outside the lock: the advertising source is app (or test)
  /// code, and `resolveVendorId` takes the lock itself.
  func submit(_ command: Command) {
    let commands = expand(command)
    lock.lock()
    defer { lock.unlock() }
    if pipe == nil, Self.survivesReset(command) {
      if resetBuffer != nil {
        bufferForResetLocked(command)
      } else if erased, let store {
        // After forgetMe, until the next start: what the erased engine
        // used to persist, persisted here.
        persistSettingCommand(command, to: store)
      }
      return
    }
    guard let pipe else { return }
    for item in commands { pipe.submit(item) }
    // F7: a grant runs the attestation the install flow skipped for consent.
    if case .setConsent(true) = command, let armed = attestationOnConsent {
      attestationOnConsent = nil
      // Only onto the engine whose install is waiting for it.
      if armed.pipe === pipe { Self.attestAfterConsent(armed.attest, pipe: pipe) }
    }
  }

  /// K2: one of each setting, in the order of their last write. The caller
  /// holds `lock`.
  private func bufferForResetLocked(_ command: Command) {
    let kind = Self.settingKind(command)
    resetBuffer?.removeAll { Self.settingKind($0) == kind }
    resetBuffer?.append(command)
  }

  /// Test surface: what a reset's drain is holding for the next pipe.
  var resetBufferKinds: [String]? {
    lock.lock()
    defer { lock.unlock() }
    return resetBuffer?.map { command in
      switch command {
      case .setConsent: return "setConsent"
      case .setConsentData: return "setConsentData"
      case .setUserId: return "setUserId"
      default: return "other"
      }
    }
  }

  private var currentAdvertisingSource: @Sendable () -> AdvertisingSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return advertisingSource
  }

  /// The commands one facade call puts on the pipe. Takes the lock (through
  /// its helpers), so it is never called while holding it.
  private func expand(_ command: Command) -> [Command] {
    switch command {
    case .flush, .foreground:
      // The MMPs read the advertising identity at send time, not at init:
      // the app may prompt through Apple's API directly, or the user may
      // flip tracking in Settings later. Refreshing here — one choke point
      // covering the timer, manual flushes, backgrounding and session open —
      // gives the same freshness. Cheap synchronous getters that never block
      // on the main thread; on platforms without ATT they return the same
      // nils init produced. `track` stays untouched: it is the hot path and
      // history is not rewritten.
      let current = currentAdvertisingSource()
      return [
        .setAdvertisingIdentity(
          idfa: current.idfa, vendorId: resolveVendorId(current.vendorId),
          limitAdTracking: current.limitAdTracking, attStatus: current.attStatus?.rawValue),
        command,
      ]
    case .setIdentity(let idfa, let vendorId, let appInstanceId, let limitAdTracking, let attStatus):
      return [
        .setIdentity(
          idfa: idfa, vendorId: resolveVendorId(vendorId), appInstanceId: appInstanceId,
          limitAdTracking: limitAdTracking, attStatus: attStatus)
      ]
    case .setAdvertisingIdentity(let idfa, let vendorId, let limitAdTracking, let attStatus):
      return [
        .setAdvertisingIdentity(
          idfa: idfa, vendorId: resolveVendorId(vendorId), limitAdTracking: limitAdTracking,
          attStatus: attStatus)
      ]
    default:
      return [command]
    }
  }

  /// What `resetInstallState` keeps (consent and the customer user id), so
  /// what a reset's drain must not drop.
  private static func survivesReset(_ command: Command) -> Bool {
    settingKind(command) != nil
  }

  private static func settingKind(_ command: Command) -> Int? {
    switch command {
    case .setConsent: return 0
    case .setConsentData: return 1
    case .setUserId: return 2
    default: return nil
    }
  }

  /// Remembers a vendor id that was read, and fills one that could not be.
  private func resolveVendorId(_ read: String?) -> String? {
    lock.lock()
    defer { lock.unlock() }
    if let read { knownVendorId = read }
    return read ?? knownVendorId
  }

  /// Erasure spans BOTH stores. The engine clears what lives in UserDefaults;
  /// the durable device id lives in the Keychain and is wiped here. Calling
  /// only the engine's `forgetMe` is the layering trap the spec recorded — an
  /// erasure that leaves the identifier behind, and looks finished.
  ///
  /// One lifecycle operation: the SDK stops (an erased engine records nothing
  /// anyway), the store fence moves so no engine, running or draining, writes
  /// behind the erasure, and the stores are wiped here, before any later
  /// operation can resolve an identity. A reset buffer is dropped with
  /// everything else; settings made afterwards, until the next start, go
  /// straight to the store.
  func forgetMe() {
    lifecycleOperation {
      lock.lock()
      // F14: a reset waiting on the server or the drain must not restart an
      // erased SDK under a fresh identity.
      generation += 1
      erasures += 1
      storeOwner += 1
      let detached = detachLocked()
      resetBuffer = nil
      // FM1: links buffered before the erasure (a reset's drain buffers them,
      // K7) belong to the identity being erased: dropped, not replayed under
      // the next one.
      pendingDeepLinks = []
      erased = true
      // Erasure clears the read caches too: a getter still answering
      // "granted" after forgetMe would report a consent the device no longer
      // holds.
      consentMirror = false
      consentDataMirror = nil
      resolvedDeviceId = nil
      startedConfig = nil
      if let store, let secure { Self.eraseStored(store: store, secure: secure) }
      lock.unlock()
      detached.cancel()
      // The engine clears its memory; its store writes are fenced off.
      detached.pipe?.submit(.forgetMe)
      detached.pipe?.shutdown()
    }
  }

  /// Everything `resetInstall` reads from this state, snapshotted at once.
  private struct ResetTarget {
    let config: AdvenueConfig
    let restart: (ResetPlan) -> Bool
    let store: any KeyValueStore
    let secure: any SecureStore
    let deviceId: String
    let resetter: (any SandboxDeviceResetting)?
    let sink: any AdvenueLogSink
    let generation: Int
  }

  private enum ResetStart {
    /// Production, or never initialized (the default environment).
    case notSandbox(any AdvenueLogSink)
    /// Sandbox, but stopped or with identity deferred: nothing to reset.
    case notRunning(any AdvenueLogSink)
    case alreadyRunning(any AdvenueLogSink)
    case ready(ResetTarget)
  }

  /// Synchronous for the reason `lookupTarget` is: NSLock is unavailable from
  /// an async context in Swift 6 mode (PF24). The environment is read first,
  /// so production logs its line even before `initialize` or while identity
  /// is deferred. A reset in flight is reported as busy before the running
  /// check (K9): during its drain the pipe is detached, and "not running" would
  /// misdescribe it. Accepting a reset claims `resetting` in the same critical
  /// section, so a double tap cannot start two.
  private func beginReset() -> ResetStart {
    lock.lock()
    defer { lock.unlock() }
    let sink = noticeSink ?? fallbackSink ?? UnifiedLogSink()
    guard let config = requestedConfig, config.environment == .sandbox else {
      return .notSandbox(sink)
    }
    guard !resetting else { return .alreadyRunning(sink) }
    guard pipe != nil, let restart, let store, let secure, let deviceId = resolvedDeviceId
    else { return .notRunning(sink) }
    resetting = true
    return .ready(
      ResetTarget(
        config: config, restart: restart, store: store, secure: secure, deviceId: deviceId,
        resetter: deviceReset, sink: sink, generation: generation))
  }

  private func endReset() {
    lock.lock()
    resetting = false
    lock.unlock()
  }

  /// Whether nobody stopped, re-initialized or erased since `expected`. Asked
  /// by the draining engine (K4), never while holding `lock`.
  private func owns(generation expected: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return generation == expected
  }

  /// The local half's first step, atomically: the pipe is still the one the
  /// reset started on (no stop, no re-initialize while the server answered),
  /// `.resetInstall` goes onto THAT pipe behind every queued command, and the
  /// pipe is detached. Nil means the SDK changed hands: do nothing further.
  ///
  /// K7: no deep link is pending here. `deepLink` buffers only while no pipe
  /// is live, and `start` empties the buffer in the critical section that
  /// installs the pipe, so with a live pipe the buffer is empty. A link that
  /// arrives during the drain is buffered and replayed by the next start, so
  /// it reaches the new install.
  private func takePipeForReset(generation expected: Int) -> CommandPipe? {
    lifecycleOperation { takePipeForResetLocked(generation: expected) }
  }

  private func takePipeForResetLocked(generation expected: Int) -> CommandPipe? {
    lock.lock()
    guard generation == expected, let pipe = self.pipe else {
      lock.unlock()
      return nil
    }
    // K4: the engine wipes the install keys only if the SDK is still the
    // reset's when it gets there.
    pipe.submit(.resetInstall(stillOwned: { [weak self] in
      self?.owns(generation: expected) ?? false
    }))
    let detached = detachLocked()
    resetBuffer = []
    lock.unlock()
    detached.cancel()
    return pipe
  }

  /// The identity half of the local reset, under `lock` inside the claiming
  /// `start`: the installation id goes (the next start mints one) and the
  /// device id is replaced by the one the reset minted (K8: the reset can
  /// return it even if that start then defers). The old installation's SKAN
  /// state goes too: it is keyed by that id, so nothing would read it again,
  /// and a reset should not leave an orphan behind.
  private func rotateInstallIdentity(
    store: any KeyValueStore, secure: any SecureStore, mintedDeviceId: String
  ) {
    if let installationId = store.string(forKey: INSTALLATION_ID_KEY) {
      store.removeObject(forKey: skanStateKey(installationId: installationId))
    }
    store.removeObject(forKey: INSTALLATION_ID_KEY)
    secure.write(mintedDeviceId, forKey: DEVICE_ID_KEY)
  }

  /// After the drain, one lifecycle operation: the restart (which claims the
  /// SDK only if nothing moved the generation) and then the settle: what the
  /// drain buffered and no start took (a stop meanwhile, a restart that
  /// deferred identity) is written to the store, so the next start loads it
  /// (K3). The old engine has drained, and the fence keeps it from writing
  /// behind anyone, so nothing writes behind this.
  private func finishReset(_ target: ResetTarget, minted: String) -> Bool {
    lifecycleOperation {
      let claimed = target.restart(
        ResetPlan(expected: target.generation, mintedDeviceId: minted))
      lock.lock()
      resetting = false
      let carried = resetBuffer ?? []
      resetBuffer = nil
      for command in carried {
        onCarryApplied?(command)
        persistSettingCommand(command, to: target.store)
      }
      lock.unlock()
      return claimed
    }
  }

  private var erasureCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return erasures
  }

  /// K24: a failure described without anything that could carry an
  /// identifier: the HTTP status for an ingest error, the type otherwise.
  static func idFree(_ error: any Error) -> String {
    if let ingest = error as? IngestError {
      return ingest.networkCause != nil ? "network error" : "status \(ingest.status)"
    }
    return String(describing: type(of: error))
  }

  /// Spec 3 §7. See `Advenue.resetInstall()`.
  ///
  /// Outcomes: the new device id; or nil, with nothing changed locally, when
  /// not in the sandbox, not running, a reset is already in flight, or the SDK
  /// was stopped, re-initialized or erased while the server answered or the
  /// pipe drained. In that last case the old engine stops, but the store is
  /// left to whoever owns the SDK now (K4), and the identity is kept.
  func resetInstall() async -> String? {
    let target: ResetTarget
    switch beginReset() {
    case .notSandbox(let sink):
      // P6: a production app must not mint "new" installs.
      sink.log(RESET_INSTALL_PRODUCTION_LOG)
      return nil
    case .notRunning(let sink):
      sink.log(RESET_INSTALL_NOT_RUNNING_LOG)
      return nil
    case .alreadyRunning(let sink):
      sink.log(RESET_INSTALL_BUSY_LOG)
      return nil
    case .ready(let ready):
      target = ready
    }
    defer { endReset() }
    // 1. Server: clear the old device's sandbox state. A 404 from an older
    //    server (or any failure, 429 included) is logged; the local reset goes
    //    on — the new device id alone gives the next install fresh continuity.
    do {
      try await target.resetter?.reset(
        deviceId: target.deviceId,
        installationId: target.store.string(forKey: INSTALLATION_ID_KEY))
    } catch {
      // K31: the app (and the debug logger, which prints what onError gets)
      // receive the id-free description, with the original kept underneath.
      target.config.onError(
        "resetInstall.server", ResetServerError(description: Self.idFree(error), underlying: error))
      target.sink.log(
        "Advenue: resetInstall() could not reset the server state (\(Self.idFree(error))); "
          + "continuing locally.")
    }
    // 2. Local: ordered behind every queued command, then wait for the pipe.
    guard let pipe = takePipeForReset(generation: target.generation) else { return nil }
    await pipe.shutdownAndWait()
    // 3. A fresh start claims the SDK, rotates the ids and records the install.
    let minted = SystemUUIDs().next()
    let erasuresBefore = erasureCount
    let claimed = finishReset(target, minted: minted)
    guard claimed else { return nil }
    // K25: erased after the claim: the minted id is gone with everything else.
    guard erasureCount == erasuresBefore else { return nil }
    // K8: the restart can defer identity (or be stopped right after the claim);
    // the reset is still done, and the id it minted is the device's from now on.
    return currentDeviceId ?? minted
  }

  /// Synchronous internally: NSLock cannot be held across an async boundary,
  /// and there is nothing to await yet. The PUBLIC accessor stays async
  /// because deferred identity will eventually wait for first unlock, and
  /// changing that signature later would break every caller.
  var resolvedAppId: String? { acceptedAppId.current }

  var trackingConsent: Bool {
    lock.lock()
    defer { lock.unlock() }
    return consentMirror
  }

  var consentData: Consent? {
    lock.lock()
    defer { lock.unlock() }
    return consentDataMirror
  }

  func rememberConsent(_ granted: Bool) {
    lock.lock()
    consentMirror = granted
    lock.unlock()
  }

  func rememberConsentData(_ consent: Consent?) {
    lock.lock()
    consentDataMirror = consent
    lock.unlock()
  }

  private func lookupTarget() -> (AdvenueConfig, String)? {
    lock.lock()
    defer { lock.unlock() }
    guard let config = startedConfig, let deviceId = resolvedDeviceId else { return nil }
    return (config, deviceId)
  }

  /// Polls the conversion lookup. Returns nil for an organic install, which is
  /// most of them.
  /// Named apart from the free function it calls, deliberately.
  ///
  /// It used to share that name and reach it through an `AdvenueCore.`
  /// qualifier. That works here and breaks in the wrapper SDKs, which flatten
  /// these modules into one — where the qualifier names nothing and dropping it
  /// would call this method again, forever. A distinct name removes the trap
  /// instead of relying on everyone remembering it.
  ///
  /// `makeFetcher` is the seam the tests use; production builds the HTTP one
  /// from the config this SDK was started with.
  func fetchDeferredDeepLink(
    makeFetcher: (AdvenueConfig, String) -> any ConversionFetcher = { config, deviceId in
      HttpConversionFetcher(
        endpoint: config.endpoint, apiKey: config.apiKey, deviceId: deviceId,
        environment: config.environment)
    },
    sleep: @escaping @Sendable (Int) async -> Void = { ms in
      try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }
  ) async -> DeepLink? {
    // Snapshot synchronously first: NSLock cannot be held across an await, and
    // the same constraint shaped `currentDeviceId`.
    guard let (config, deviceId) = lookupTarget() else { return nil }
    return await resolveDeferredDeepLink(
      fetcher: makeFetcher(config, deviceId), sleep: sleep)
  }

  var currentDeviceId: String? {
    lock.lock()
    defer { lock.unlock() }
    return resolvedDeviceId
  }

  func setAppInstanceIdProvider(_ provider: @escaping @Sendable () async -> String?) {
    lock.lock()
    appInstanceIdProvider = provider
    lock.unlock()
  }

  /// K21: the pipe check and the submit are one critical section, so a reset
  /// that takes the pipe in between cannot drop the link: with no pipe it is
  /// buffered, and the next start replays it here.
  func deepLink(_ url: URL) {
    // B3: ham query gönderilmez — token/e-posta query'de taşınır. AEM
    // ayrıştırması ve hash TAM url'den yapılır (aşağıda).
    let track = Command.track(
      name: "deep_link", properties: ["url": .string(stripUrlQuery(url))], type: "custom")
    // Meta AEM: a link from Meta carries al_applink_data with an opaque,
    // Meta-encrypted campaign_ids blob. Emitted at most once per URL — the same
    // link re-opened is not a second measurement, and the server dedups on this
    // hash too.
    var aem: (hash: String, command: Command)?
    if let applink = URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?.first(where: { $0.name == "al_applink_data" })?.value,
      let campaignIds = extractAemCampaignIds(applink)
    {
      let hash = sha256Hex(url.absoluteString)
      aem = (
        hash,
        .track(
          name: "adv_meta_aem",
          properties: ["campaignIds": .string(campaignIds), "sourceUrlHash": .string(hash)],
          type: "custom")
      )
    }
    lock.lock()
    defer { lock.unlock() }
    guard let pipe else {
      // FM1: after forgetMe, until the next start, the link is dropped, as the
      // erased engine dropped it. Before the first start, or during a reset's
      // drain (K7), it waits for the next pipe.
      if !erased { pendingDeepLinks.append(url) }
      return
    }
    pipe.submit(track)
    if let aem, seenAemUrlHashes.insert(aem.hash).inserted { pipe.submit(aem.command) }
  }

  /// Test surface: how many links are waiting for `initialize`.
  var bufferedDeepLinkCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return pendingDeepLinks.count
  }

  /// B3: deep-link URL'sinden query+fragment atılır. URLComponents
  /// çözümlenemezse ham dizenin `?`/`#` öncesi alınır (asla ham query sızmaz).
  func stripUrlQuery(_ url: URL) -> String {
    if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
      components.query = nil
      components.fragment = nil
      if let stripped = components.string { return stripped }
    }
    let raw = url.absoluteString
    if let cut = raw.firstIndex(where: { $0 == "?" || $0 == "#" }) {
      return String(raw[..<cut])
    }
    return raw
  }

  /// Subscribes to the app's own lifecycle, so an integrator does not have to.
  ///
  /// The Android SDK has always done this through `ActivityLifecycleCallbacks`;
  /// iOS did not, and the asymmetry had no stated reason. Its cost was real: a
  /// native app opened one session at launch and then never another, because a
  /// return from background after the session window went unnoticed — and
  /// backgrounding neither closed the session nor flushed, so a batch could sit
  /// on the device until the next launch.
  ///
  /// `NotificationCenter` rather than `UIApplication.shared`, deliberately:
  /// the notification names are plain constants, while `shared` is unavailable
  /// in an app extension and merely referencing it there fails to link.
  private func observeLifecycle(seededInForeground: Bool) {
    // Seeded OUTSIDE the UIKit guard, deliberately. The tracker's state is
    // platform-independent and must be right even where no observer can be
    // registered — a macOS test process, for one, which is exactly where
    // leaving it inside the guard made a signal read as a fresh foreground.
    lock.lock()
    foreground = ForegroundTracker(inForeground: seededInForeground)
    lock.unlock()

    #if canImport(UIKit)
      let signals: [(Notification.Name, LifecycleSignal)] = [
        (UIApplication.didBecomeActiveNotification, .didBecomeActive),
        (UIApplication.willResignActiveNotification, .willResignActive),
        (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
      ]
      var registered: [NSObjectProtocol] = []
      for (name, signal) in signals {
        registered.append(
          NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: nil
          ) { [weak self] _ in
            self?.handle(signal)
          })
      }
      lock.lock()
      lifecycleObservers = registered
      lock.unlock()
    #endif
  }

  /// The public lifecycle calls go through the same tracker as UIKit's signals,
  /// so one forwarded while already foregrounded (or already backgrounded) is a
  /// no-op instead of a session split.
  func notifyForeground() { handle(.didBecomeActive) }
  func notifyBackground() { handle(.didEnterBackground) }

  /// Applies one lifecycle signal. Public routing lives here rather than in the
  /// observer closure so a test can drive it without UIKit.
  func handle(_ signal: LifecycleSignal) {
    lock.lock()
    let transition = foreground.on(signal)
    lock.unlock()
    switch transition {
    case .none:
      return
    case .enteredForeground:
      submit(.foreground)
    case .enteredBackground:
      // Backgrounding both closes the session and flushes: a batch stranded at
      // the moment the app leaves the foreground may not be sent for hours.
      submit(.background)
      submit(.flush)
    }
  }

  /// What a detach takes off this state, cancelled outside the lock.
  private struct Detached {
    let pipe: CommandPipe?
    let timer: DispatchSourceTimer?
    let observers: [NSObjectProtocol]
    let install: Task<Void, Never>?

    /// Cancel before the pipe shuts down: a timer firing into a finished
    /// stream is harmless, but leaving it running leaks a repeating source per
    /// initialize() call. The observers go for the same reason, one instance
    /// further out. The install task can be mid-wait for up to two minutes —
    /// without the cancel it would submit a stale install into the next pipe.
    func cancel() {
      timer?.cancel()
      install?.cancel()
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
  }

  /// Detaches the pipe, timers, observers and the install task. The caller
  /// holds `lock`.
  private func detachLocked() -> Detached {
    let detached = Detached(
      pipe: pipe, timer: flushTimer, observers: lifecycleObservers, install: installTask)
    pipe = nil
    flushTimer = nil
    lifecycleObservers = []
    installTask = nil
    attestationOnConsent = nil
    return detached
  }

  func stop() {
    lifecycleOperation {
      lock.lock()
      // A reset waiting on the server or the drain must not revive what this stops.
      generation += 1
      let detached = detachLocked()
      // K23: a stopped SDK answers for no device: deviceId() is nil and the
      // deferred-deep-link lookup does not poll.
      resolvedDeviceId = nil
      startedConfig = nil
      lock.unlock()
      detached.cancel()
      detached.pipe?.shutdown()
    }
  }

  /// Test surface: whether a pipe is live.
  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return pipe != nil
  }
}

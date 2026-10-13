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

  /// Erasure. Spans both stores — see `FacadeState.forgetMe`.
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
  /// What `resetInstall` needs to start again exactly as the app did.
  private var restart: (() -> Void)?
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
  private var resetBuffer: [Command]?

  init(fallbackSink: (any AdvenueLogSink)? = nil) {
    self.fallbackSink = fallbackSink
  }

  /// `transport` is a parameter, not a hidden construction, because an unwired
  /// transport is otherwise invisible: every component of the send path can be
  /// green while nothing joins them. `SeamTests` injects a recorder here.
  func start(
    _ config: AdvenueConfig,
    transport: (any EventTransport)? = nil,
    sources: EnrichmentSources? = nil,
    skan skanReporter: (any SkanReporter)? = nil,
    appVersion readVersion: @escaping () -> String? = readAppVersion,
    launchedInBackground: @escaping () -> Bool = readLaunchedInBackground,
    logSink: (any AdvenueLogSink)? = nil,
    advertisingSource: (@Sendable () -> AdvertisingSnapshot)? = nil,
    deviceReset: (any SandboxDeviceResetting)? = nil
  ) {
    // Replace-and-shut-down, never add.
    stop()

    // `resetInstall` restarts with exactly these arguments, so a reset app
    // runs with the same transport, sources and sinks it was started with.
    let requestedConfig = config
    let restartArgs: () -> Void = { [weak self] in
      self?.start(
        requestedConfig, transport: transport, sources: sources, skan: skanReporter,
        appVersion: readVersion, launchedInBackground: launchedInBackground, logSink: logSink,
        advertisingSource: advertisingSource, deviceReset: deviceReset)
    }
    // Recorded before the identity gate, so a reset on a deferred launch
    // still knows the environment it was asked for (and says so).
    lock.lock()
    self.restart = restartArgs
    self.requestedConfig = requestedConfig
    self.noticeSink = logSink
    self.deviceReset =
      deviceReset
      ?? HttpSandboxDeviceReset(
        endpoint: requestedConfig.endpoint, apiKey: requestedConfig.apiKey,
        signingSecret: requestedConfig.signingSecret)
    lock.unlock()

    // `debug`: every swallowed failure goes through onError, so logging there
    // covers all of them — wrapped once, before anything below captures it.
    let (debugConfig, log) = withDebugLogging(config, sink: logSink)
    let config = withSandboxNotices(debugConfig, sink: logSink)

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
    let secure = KeychainStore()
    let uuid = SystemUUIDs()

    let identity = resolveIdentity(secure: secure, store: store, uuid: uuid)
    guard case .resolved(let deviceId, let installationId) = identity else {
      // Deferred: the Keychain could not be read. Nothing is minted and
      // nothing starts, so no event carries an invented identifier. The next
      // launch after first unlock resolves it.
      config.onError("identity.deferred", AdvenueSetupError.identityDeferred)
      return
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
    let eventTransport: any EventTransport =
      config.debug ? LoggingTransport(inner: baseTransport, log: log) : baseTransport

    let engine = AdvenueEngine(
      config: EngineConfig(
        apiKey: config.apiKey, platform: "ios", deviceId: deviceId,
        installationId: installationId, appVersion: readVersion(),
        osVersion: osVersion,
        sdkVersion: String((config.sdkVersion ?? AdvenueVersion.current).prefix(32)),
        requireConsent: config.requireConsent, sessionWindowMs: config.sessionWindowMs,
        batchSize: config.batchSize, piiScrubEnabled: config.piiScrubEnabled,
        attStatus: AdvertisingIdentity().status.rawValue),
      store: store, clock: SystemClock(), scheduler: scheduler, uuid: uuid,
      transport: eventTransport,
      onError: config.onError)
    let pipe = CommandPipe(engine: engine, onError: config.onError)

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
    // F13: what the app set while a reset drained, in order, ahead of the
    // install, and reflected in the getters the store just reseeded.
    let carried = resetBuffer ?? []
    resetBuffer = nil
    for command in carried {
      switch command {
      case .setConsent(let granted): consentMirror = granted
      case .setConsentData(let consent): consentDataMirror = consent
      default: break
      }
      pipe.submit(command)
    }
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
    for url in buffered { send(url) }
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
    let installSources =
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
  }

  private var currentAppInstanceIdProvider: (@Sendable () async -> String?)? {
    lock.lock()
    defer { lock.unlock() }
    return appInstanceIdProvider
  }

  func submit(_ command: Command) {
    lock.lock()
    let pipe = self.pipe
    let source = self.advertisingSource
    if pipe == nil, resetBuffer != nil, Self.survivesReset(command) {
      resetBuffer?.append(command)
      lock.unlock()
      return
    }
    lock.unlock()
    guard let pipe else { return }
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
      let current = source()
      pipe.submit(
        .setAdvertisingIdentity(
          idfa: current.idfa, vendorId: resolveVendorId(current.vendorId),
          limitAdTracking: current.limitAdTracking, attStatus: current.attStatus?.rawValue))
      pipe.submit(command)
    case .setIdentity(let idfa, let vendorId, let appInstanceId, let limitAdTracking, let attStatus):
      pipe.submit(
        .setIdentity(
          idfa: idfa, vendorId: resolveVendorId(vendorId), appInstanceId: appInstanceId,
          limitAdTracking: limitAdTracking, attStatus: attStatus))
    case .setAdvertisingIdentity(let idfa, let vendorId, let limitAdTracking, let attStatus):
      pipe.submit(
        .setAdvertisingIdentity(
          idfa: idfa, vendorId: resolveVendorId(vendorId), limitAdTracking: limitAdTracking,
          attStatus: attStatus))
    default:
      pipe.submit(command)
    }
  }

  /// What `resetInstallState` keeps (consent and the customer user id), so
  /// what a reset's drain must not drop.
  private static func survivesReset(_ command: Command) -> Bool {
    switch command {
    case .setConsent, .setConsentData, .setUserId: return true
    default: return false
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
  func forgetMe() {
    submit(.forgetMe)
    lock.lock()
    // F14: a reset waiting on the server must not restart an erased SDK under
    // a fresh identity.
    generation += 1
    // Erasure clears the read caches too: a getter still answering "granted"
    // after forgetMe would report a consent the device no longer holds.
    consentMirror = false
    consentDataMirror = nil
    let secure = self.secure
    let store = self.store
    resolvedDeviceId = nil
    lock.unlock()
    secure?.delete(DEVICE_ID_KEY)
    store?.removeObject(forKey: INSTALLATION_ID_KEY)
    store?.removeObject(forKey: INSTALL_SENT_KEY)
  }

  /// Everything `resetInstall` reads from this state, snapshotted at once.
  private struct ResetTarget {
    let config: AdvenueConfig
    let restart: () -> Void
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
  /// is deferred. Accepting a reset claims `resetting` in the same critical
  /// section, so a double tap cannot start two.
  private func beginReset() -> ResetStart {
    lock.lock()
    defer { lock.unlock() }
    let sink = noticeSink ?? fallbackSink ?? UnifiedLogSink()
    guard let config = requestedConfig, config.environment == .sandbox else {
      return .notSandbox(sink)
    }
    guard pipe != nil, let restart, let store, let secure, let deviceId = resolvedDeviceId
    else { return .notRunning(sink) }
    guard !resetting else { return .alreadyRunning(sink) }
    resetting = true
    return .ready(
      ResetTarget(
        config: config, restart: restart, store: store, secure: secure, deviceId: deviceId,
        resetter: deviceReset, sink: sink, generation: generation))
  }

  private func endReset() {
    lock.lock()
    resetting = false
    resetBuffer = nil
    lock.unlock()
  }

  /// A reset that gave up after detaching the pipe: what was buffered goes to
  /// whatever pipe exists now (none, if the SDK was stopped).
  private func releaseResetBuffer() {
    lock.lock()
    let carried = resetBuffer ?? []
    resetBuffer = nil
    lock.unlock()
    for command in carried { submit(command) }
  }

  /// The local half's first step, atomically: the pipe is still the one the
  /// reset started on (no stop, no re-initialize while the server answered),
  /// `.resetInstall` goes onto THAT pipe behind every queued command, and the
  /// pipe is detached. Nil means the SDK changed hands: do nothing further.
  private func takePipeForReset(generation expected: Int) -> CommandPipe? {
    lock.lock()
    guard generation == expected, let pipe = self.pipe else {
      lock.unlock()
      return nil
    }
    pipe.submit(.resetInstall)
    let detached = detachLocked()
    resetBuffer = []
    lock.unlock()
    detached.cancel()
    return pipe
  }

  /// After the drain: claims the restart only if nobody stopped or
  /// re-initialized meanwhile, and forgets the in-memory identity with it.
  /// (The restart itself runs `start`, which takes the lock, so it follows
  /// this check rather than sitting inside it; no await separates them.)
  private func claimRestart(generation expected: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard generation == expected else { return false }
    pendingDeepLinks = []
    resolvedDeviceId = nil
    return true
  }

  /// The identity half of the local reset, once the engine has drained: the
  /// next start mints a new device id and installation id. The old
  /// installation's SKAN state goes too: it is keyed by that id, so nothing
  /// would read it again, and a reset should not leave an orphan behind.
  private func forgetInstallIdentity(store: any KeyValueStore, secure: any SecureStore) {
    if let installationId = store.string(forKey: INSTALLATION_ID_KEY) {
      store.removeObject(forKey: skanStateKey(installationId: installationId))
    }
    store.removeObject(forKey: INSTALLATION_ID_KEY)
    secure.delete(DEVICE_ID_KEY)
  }

  /// Spec 3 §7. See `Advenue.resetInstall()`.
  ///
  /// Outcomes: the new device id; or nil, with nothing changed locally, when
  /// not in the sandbox, not running, a reset is already in flight, or the SDK
  /// was stopped or re-initialized while the server answered. If that happens
  /// during the (short) local drain instead, the engine's reset has run but
  /// the identity is kept and nothing restarts: a stopped SDK stays stopped.
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
      target.config.onError("resetInstall.server", error)
      target.sink.log(
        "Advenue: resetInstall() could not reset the server state (\(error)); continuing locally.")
    }
    // 2. Local: ordered behind every queued command, then wait for the pipe.
    guard let pipe = takePipeForReset(generation: target.generation) else { return nil }
    await pipe.shutdownAndWait()
    guard claimRestart(generation: target.generation) else {
      releaseResetBuffer()
      return nil
    }
    forgetInstallIdentity(store: target.store, secure: target.secure)
    // 3. A fresh start mints the ids and records the install.
    target.restart()
    return currentDeviceId
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
  func fetchDeferredDeepLink() async -> DeepLink? {
    // Snapshot synchronously first: NSLock cannot be held across an await, and
    // the same constraint shaped `currentDeviceId`.
    guard let (config, deviceId) = lookupTarget() else { return nil }
    return await resolveDeferredDeepLink(
      fetcher: HttpConversionFetcher(
        endpoint: config.endpoint, apiKey: config.apiKey, deviceId: deviceId,
        environment: config.environment))
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

  func deepLink(_ url: URL) {
    lock.lock()
    let started = pipe != nil
    if !started { pendingDeepLinks.append(url) }
    lock.unlock()
    if started { send(url) }
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

  private func send(_ url: URL) {
    // B3: ham query gönderilmez — token/e-posta query'de taşınır. AEM
    // ayrıştırması ve hash TAM url'den yapılır (aşağıda).
    submit(
      .track(
        name: "deep_link", properties: ["url": .string(stripUrlQuery(url))], type: "custom"))

    // Meta AEM: a link from Meta carries al_applink_data with an opaque,
    // Meta-encrypted campaign_ids blob. Emitted at most once per URL — the same
    // link re-opened is not a second measurement, and the server dedups on this
    // hash too.
    guard
      let applink = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "al_applink_data" })?.value,
      let campaignIds = extractAemCampaignIds(applink)
    else { return }

    let hash = sha256Hex(url.absoluteString)
    lock.lock()
    let fresh = seenAemUrlHashes.insert(hash).inserted
    lock.unlock()
    guard fresh else { return }

    submit(
      .track(
        name: "adv_meta_aem",
        properties: ["campaignIds": .string(campaignIds), "sourceUrlHash": .string(hash)],
        type: "custom"))
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
    return detached
  }

  func stop() {
    lock.lock()
    // A reset waiting on the server or the drain must not revive what this stops.
    generation += 1
    let detached = detachLocked()
    lock.unlock()
    detached.cancel()
    detached.pipe?.shutdown()
  }

  /// Test surface: whether a pipe is live.
  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return pipe != nil
  }
}

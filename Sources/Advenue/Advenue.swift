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

  public static func notifyForeground() { state.submit(.foreground) }

  /// Backgrounding both closes the session and flushes: a batch stranded at the
  /// moment the app leaves the foreground may not be sent for hours.
  public static func notifyBackground() {
    state.submit(.background)
    state.submit(.flush)
  }

  /// Presents the ATT prompt. The app decides when; the SDK never prompts on
  /// its own.
  @discardableResult
  public static func requestTrackingAuthorization() async -> TrackingAuthorization {
    await AdvertisingIdentity().requestAuthorization()
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

/// Thread-safe holder for the app the server reported. Diagnostics only.
final class AcceptedAppId: @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?

  var current: String? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set(_ appId: String) {
    lock.lock()
    value = appId
    lock.unlock()
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
  /// Read caches for the two consent values. The engine owns persistence; these
  /// exist so a synchronous getter can answer without a round trip through the
  /// pipe, and so a caller reading back its own `setConsent` never sees the
  /// value it just replaced.
  private var consentMirror = false
  private var consentDataMirror: Consent?

  /// `transport` is a parameter, not a hidden construction, because an unwired
  /// transport is otherwise invisible: every component of the send path can be
  /// green while nothing joins them. `SeamTests` injects a recorder here.
  func start(
    _ config: AdvenueConfig,
    transport: (any EventTransport)? = nil,
    sources: EnrichmentSources? = nil,
    skan skanReporter: (any SkanReporter)? = nil
  ) {
    // Replace-and-shut-down, never add.
    stop()

    let store = UserDefaultsStore()
    let secure = KeychainStore()
    let uuid = SystemUUIDs()

    let identity = resolveIdentity(secure: secure, store: store, uuid: uuid)
    guard case .resolved(let deviceId, let installationId) = identity else {
      // Deferred: the Keychain could not be read. Nothing is minted and
      // nothing starts, so no event carries an invented identifier. The next
      // launch after first unlock resolves it.
      config.onError("identity.deferred", IngestError(status: 0))
      return
    }

    let osVersion: String?
    #if canImport(UIKit)
      osVersion = UIDevice.current.systemVersion
    #else
      osVersion = nil
    #endif

    let eventTransport =
      transport
      ?? HttpTransport(
        endpoint: config.endpoint, apiKey: config.apiKey,
        signingSecret: config.signingSecret,
        // Diagnostics only: it runs after the batch is already accepted, so
        // nothing it does can turn a successful ingest into a failure.
        onAccepted: { [acceptedAppId] appId in acceptedAppId.set(appId) })

    let engine = AdvenueEngine(
      config: EngineConfig(
        apiKey: config.apiKey, platform: "ios", deviceId: deviceId,
        installationId: installationId, appVersion: config.appVersion,
        osVersion: osVersion, sdkVersion: AdvenueVersion.current,
        requireConsent: config.requireConsent, sessionWindowMs: config.sessionWindowMs,
        batchSize: config.batchSize),
      store: store, clock: SystemClock(), scheduler: TimerScheduler(), uuid: uuid,
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
    // Seeded from the same persisted values the engine loads, so consent
    // granted in a previous run is still granted after a cold start.
    self.consentMirror = store.string(forKey: CONSENT_KEY) == "granted"
    self.consentDataMirror = readPersistedConsentData(store)
    self.pipe = pipe
    self.resolvedDeviceId = deviceId
    let buffered = pendingDeepLinks
    pendingDeepLinks = []
    lock.unlock()

    // Replayed in arrival order, before the first session, so a deferred deep
    // link is attributed to the launch it belongs to.
    for url in buffered { send(url) }
    pipe.submit(.foreground)

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
    Task { [weak self] in
      let enrichment = await collectEnrichment(installSources, deadlineMs: INSTALL_WINDOW_MS)
      self?.submit(
        .setIdentity(
          idfa: enrichment.idfa, vendorId: enrichment.vendorId,
          appInstanceId: enrichment.appInstanceId))
      self?.submit(.setDeviceInfo(collectDeviceInfo()))
      // The CMP writes TCF to the standard defaults, and reading it is the
      // difference between shipping a real consent signal and shipping none.
      // Submitted before the install so the first event carries it.
      if let consent = readTcf() { self?.submit(.setConsentData(consent)) }
      self?.submit(
        .trackInstall(
          adservicesToken: enrichment.adservicesToken,
          attestation: enrichment.attestation,
          attestationChallenge: enrichment.attestationChallenge))
      self?.submit(.flush)
    }
  }

  private var currentAppInstanceIdProvider: (@Sendable () async -> String?)? {
    lock.lock()
    defer { lock.unlock() }
    return appInstanceIdProvider
  }

  func submit(_ command: Command) {
    lock.lock()
    let pipe = self.pipe
    lock.unlock()
    pipe?.submit(command)
  }

  /// Erasure spans BOTH stores. The engine clears what lives in UserDefaults;
  /// the durable device id lives in the Keychain and is wiped here. Calling
  /// only the engine's `forgetMe` is the layering trap the spec recorded — an
  /// erasure that leaves the identifier behind, and looks finished.
  func forgetMe() {
    submit(.forgetMe)
    lock.lock()
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
        endpoint: config.endpoint, apiKey: config.apiKey, deviceId: deviceId))
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

  private func send(_ url: URL) {
    submit(
      .track(
        name: "deep_link", properties: ["url": .string(url.absoluteString)], type: "custom"))

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

  func stop() {
    lock.lock()
    let pipe = self.pipe
    let timer = flushTimer
    self.pipe = nil
    flushTimer = nil
    lock.unlock()
    // Cancel before the pipe shuts down: a timer firing into a finished stream
    // is harmless, but leaving it running leaks a repeating source per
    // initialize() call.
    timer?.cancel()
    pipe?.shutdown()
  }
}

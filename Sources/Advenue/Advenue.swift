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
  }

  public static func setUserId(_ id: String?) { state.submit(.setUserId(id)) }
  public static func setConsent(_ granted: Bool) { state.submit(.setConsent(granted)) }

  /// Granular ad-platform consent (Google DMA), forwarded by server-side
  /// postbacks as gdpr_applies / ad_user_data / ad_personalization / ad_storage.
  ///
  /// Leave a field nil when the user has not been asked: "not stated" is not
  /// "denied", and inventing false on their behalf records a refusal that never
  /// happened.
  public static func setConsentData(_ consent: Consent?) {
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
    await state.resolveDeferredDeepLink()
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
  private var appInstanceIdProvider: (@Sendable () async -> String?)?
  private var flushTimer: DispatchSourceTimer?

  /// `transport` is a parameter, not a hidden construction, because an unwired
  /// transport is otherwise invisible: every component of the send path can be
  /// green while nothing joins them. `SeamTests` injects a recorder here.
  func start(
    _ config: AdvenueConfig,
    transport: (any EventTransport)? = nil,
    sources: EnrichmentSources? = nil
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

    lock.lock()
    self.store = store
    self.secure = secure
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
      sources ?? EnrichmentSources.system(appInstanceIdProvider: currentAppInstanceIdProvider)
    Task { [weak self] in
      let enrichment = await collectEnrichment(installSources, deadlineMs: INSTALL_WINDOW_MS)
      self?.submit(
        .setIdentity(
          idfa: enrichment.idfa, vendorId: enrichment.vendorId,
          appInstanceId: enrichment.appInstanceId))
      self?.submit(.setDeviceInfo(collectDeviceInfo()))
      self?.submit(.trackInstall(adservicesToken: enrichment.adservicesToken))
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

  private func lookupTarget() -> (AdvenueConfig, String)? {
    lock.lock()
    defer { lock.unlock() }
    guard let config = startedConfig, let deviceId = resolvedDeviceId else { return nil }
    return (config, deviceId)
  }

  /// Polls the conversion lookup. Returns nil for an organic install, which is
  /// most of them.
  func resolveDeferredDeepLink() async -> DeepLink? {
    // Snapshot synchronously first: NSLock cannot be held across an await, and
    // the same constraint shaped `currentDeviceId`.
    guard let (config, deviceId) = lookupTarget() else { return nil }
    return await AdvenueCore.resolveDeferredDeepLink(
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

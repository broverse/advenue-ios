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

/// Holds what a static facade cannot: the live engine, the command pipe, the
/// pre-init deep-link buffer and the resolved identity.
final class FacadeState: @unchecked Sendable {
  private let lock = NSLock()
  private var pipe: CommandPipe?
  private var secure: (any SecureStore)?
  private var store: (any KeyValueStore)?
  private var resolvedDeviceId: String?
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
        signingSecret: config.signingSecret)

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

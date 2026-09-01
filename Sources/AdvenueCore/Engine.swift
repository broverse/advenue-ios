import Foundation

public struct EngineConfig: Sendable {
  public var apiKey: String
  public var platform: String
  public var deviceId: String
  public var installationId: String?
  public var appVersion: String?
  public var osVersion: String?
  public var sdkVersion: String?
  public var requireConsent: Bool
  public var sessionWindowMs: Int64
  public var maxQueueSize: Int
  /// Events per request, and the threshold at which `track` flushes eagerly.
  public var batchSize: Int
  public var retryBaseMs: Double
  public var retryCapMs: Double

  public init(
    apiKey: String, platform: String, deviceId: String, installationId: String? = nil,
    appVersion: String? = nil, osVersion: String? = nil, sdkVersion: String? = nil,
    requireConsent: Bool = false, sessionWindowMs: Int64 = DEFAULT_SESSION_WINDOW_MS,
    maxQueueSize: Int = 10_000, batchSize: Int = 20,
    retryBaseMs: Double = 1_000, retryCapMs: Double = 60_000
  ) {
    self.batchSize = batchSize
    self.retryBaseMs = retryBaseMs
    self.retryCapMs = retryCapMs
    self.apiKey = apiKey
    self.platform = platform
    self.deviceId = deviceId
    self.installationId = installationId
    self.appVersion = appVersion
    self.osVersion = osVersion
    self.sdkVersion = sdkVersion
    self.requireConsent = requireConsent
    self.sessionWindowMs = sessionWindowMs
    self.maxQueueSize = maxQueueSize
  }
}

/// The server rejects a batch of more than this: `eventBatchSchema` in
/// `packages/shared/src/events.ts` is `z.array(clientEventSchema).min(1).max(100)`.
///
/// It lives in the core rather than beside the transport because it is a fact
/// about the wire, not about any one way of reaching it — and because the
/// engine has to clamp to it, which the transport cannot do from where it sits.
public let MAX_BATCH_SIZE = 100

/// Dies with the app; guards the one-per-install first-open event. Lives in the
/// core because the engine owns the guard — the Keychain is deliberately never
/// consulted for it, since a durable flag would suppress legitimate reinstalls.
public let INSTALL_SENT_KEY = "advenue.install_sent"
public let CONSENT_KEY = "advenue.consent"
public let CONSENT_DATA_KEY = "advenue.consent_data"
public let USER_ID_KEY = "advenue.user_id"

/// Owns every piece of mutable SDK state. Commands arrive through an ordered
/// `AsyncStream` and are handled one at a time, which reproduces sdk-core's
/// single-threaded semantics — the property that makes the conformance vectors
/// meaningful in the first place.
public actor AdvenueEngine {
  private let config: EngineConfig
  private let store: KeyValueStore
  private let clock: Clock
  private let uuid: UUIDSource
  private let queue: EventQueue
  private let sessions: SessionTracker
  private let onError: @Sendable (String, any Error) -> Void
  private let transport: (any EventTransport)?
  private let onDrop: @Sendable ([ClientEvent]) -> Void
  private let random: @Sendable () -> Double

  private var consent: Bool
  private var forgotten = false
  private var customerUserId: String?
  private var idfa: String?
  private var vendorId: String?
  private var appInstanceId: String?
  private var consentData: Consent?
  private var pushToken: String?
  private var pushProvider: String?
  private var deviceInfo: [String: AdvenueValue]?
  /// An install refused because consent was closed, kept so granting consent
  /// later still sends one. Without this an app using `requireConsent` that
  /// gets consent after launch never sends an install at all — no install, no
  /// attribution, for the life of that installation.
  private var installDeferred: (token: String?, properties: [String: AdvenueValue]?,
    attestation: AttestationResult?, challenge: String?)?
  private var skan: SkanStateMachine?
  private var skanReporter: (any SkanReporter)?
  private var flushing = false
  private var consecutiveFailures = 0
  private var backoffUntilMs: Int64 = 0

  public init(
    config: EngineConfig,
    store: KeyValueStore,
    clock: Clock,
    scheduler: Scheduler,
    uuid: UUIDSource,
    transport: (any EventTransport)? = nil,
    onDrop: @escaping @Sendable ([ClientEvent]) -> Void = { _ in },
    random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
    onError: @escaping @Sendable (String, any Error) -> Void = { _, _ in }
  ) {
    self.config = config
    self.store = store
    self.clock = clock
    self.uuid = uuid
    self.transport = transport
    self.onDrop = onDrop
    self.random = random
    self.onError = onError
    self.queue = EventQueue(store: store, maxSize: config.maxQueueSize, scheduler: scheduler)
    self.sessions = SessionTracker(
      store: store, clock: clock, windowMs: config.sessionWindowMs, uuid: uuid)
    self.consent = store.string(forKey: CONSENT_KEY) == "granted"
    self.consentData = readPersistedConsentData(store)
  }

  /// Enqueues an event, or refuses it and says why. Returns whether it was
  /// accepted, mirroring sdk-core's `track()`.
  @discardableResult
  public func track(
    _ name: String,
    properties: [String: AdvenueValue]? = nil,
    type: String = "custom"
  ) -> Bool {
    if forgotten || (config.requireConsent && !consent) { return false }
    if let rejection = checkTrackInput(name: name, properties: properties) {
      onError("track.rejected:\(rejection.rawValue)", IngestError(status: 400))
      return false
    }

    var event = ClientEvent(
      id: uuid.next(), deviceId: config.deviceId, type: type, name: name,
      timestamp: EventEncoding.iso8601(ms: clock.nowMs()), platform: config.platform)
    event.installationId = config.installationId
    event.appVersion = config.appVersion
    event.osVersion = config.osVersion
    event.sdkVersion = config.sdkVersion
    event.customerUserId = customerUserId
    event.idfa = idfa
    event.vendorId = vendorId
    event.appInstanceId = appInstanceId
    event.consent = consentData
    // Lifecycle events only — see trackInstall.
    if type == "session" {
      event.pushToken = pushToken
      event.pushProvider = pushProvider
    }
    event.properties = properties
    queue.enqueue(event)
    return true
  }

  /// Identity attached to every subsequent event. Not persisted: it is
  /// re-resolved each launch, because ATT status and the vendor id can both
  /// change between them.
  public func setIdentity(idfa: String?, vendorId: String?, appInstanceId: String?) {
    self.idfa = idfa
    self.vendorId = vendorId
    self.appInstanceId = appInstanceId
  }

  /// The Firebase App Instance ID alone. Separate from `setIdentity` because it
  /// arrives on its own schedule — an app can set it at any point, and folding
  /// it into the three-field setter would clear the advertising identity the
  /// install enrichment resolved.
  public func setAppInstanceId(_ id: String?) {
    appInstanceId = id
  }

  /// The first-open event, at most once per installation. Returns whether it
  /// was recorded.
  ///
  /// Ordering is deliberate. The consent gate comes first, so a refused install
  /// leaves no flag and can still fire once consent arrives. The flag is
  /// written last, so a crash between the event and the flag costs a duplicate
  /// the backend dedup window absorbs — a permanently missing install is the
  /// worse failure.
  @discardableResult
  public func trackInstall(
    adservicesToken: String?, properties: [String: AdvenueValue]? = nil,
    attestation: AttestationResult? = nil, attestationChallenge: String? = nil
  ) -> Bool {
    if forgotten { return false }
    if config.requireConsent && !consent {
      installDeferred = (adservicesToken, properties, attestation, attestationChallenge)
      return false
    }
    if store.string(forKey: INSTALL_SENT_KEY) == "1" { return false }

    var event = ClientEvent(
      id: uuid.next(), deviceId: config.deviceId, type: "install", name: "install",
      timestamp: EventEncoding.iso8601(ms: clock.nowMs()), platform: config.platform)
    event.installationId = config.installationId
    event.appVersion = config.appVersion
    event.osVersion = config.osVersion
    event.sdkVersion = config.sdkVersion
    event.customerUserId = customerUserId
    event.idfa = idfa
    event.vendorId = vendorId
    event.appInstanceId = appInstanceId
    event.consent = consentData
    // Lifecycle events only. A push token is ~180 bytes and the registry needs
    // it periodically, not on every custom event in a 100-event batch.
    event.pushToken = pushToken
    event.pushProvider = pushProvider
    // Install-only: an attribution input, not a per-event property.
    event.adservicesToken = adservicesToken
    if let attestation {
      event.attestationToken = attestation.attestationObject
      event.attestationType = "app-attest"
      event.attestationKeyId = attestation.keyId
      event.attestationChallenge = attestationChallenge
    }
    // Merged rather than replacing: a caller-supplied property of the same name
    // is the app's own and wins.
    if let deviceInfo {
      event.properties = deviceInfo.merging(properties ?? [:]) { _, caller in caller }
    } else {
      event.properties = properties
    }
    queue.enqueue(event)

    store.set("1", forKey: INSTALL_SENT_KEY)
    return true
  }

  public func setConsent(_ granted: Bool) {
    consent = granted
    store.set(granted ? "granted" : "denied", forKey: CONSENT_KEY)

    // Granting consent releases an install that was refused for the lack of it.
    guard granted, let deferred = installDeferred else { return }
    installDeferred = nil
    trackInstall(
      adservicesToken: deferred.token, properties: deferred.properties,
      attestation: deferred.attestation, attestationChallenge: deferred.challenge)
  }

  /// Granular ad-platform consent. Last write wins and it is persisted, so it
  /// survives restarts — a stated preference silently reverting on relaunch is
  /// the failure this guards.
  public func setConsentData(_ consent: Consent?) {
    guard !forgotten else { return }
    consentData = consent
    guard let consent else {
      store.removeObject(forKey: CONSENT_DATA_KEY)
      return
    }
    if let data = try? EventEncoding.canonicalEncoder().encode(consent) {
      store.set(String(decoding: data, as: UTF8.self), forKey: CONSENT_DATA_KEY)
    }
  }

  public func getConsentData() -> Consent? { consentData }

  /// Device metadata attached to the install event, where Meta CAPI reads it.
  public func setDeviceInfo(_ info: [String: AdvenueValue]) { deviceInfo = info }

  /// Arms SKAN. Without a conversion-value config there is nothing to report,
  /// so the machine is not built at all rather than built and idle.
  ///
  /// The machine is constructed **here**, on the actor, from Sendable
  /// ingredients. Building it outside and passing it in is what Swift 6 refuses
  /// — it holds the store, which belongs to this actor — and the refusal is
  /// correct rather than something to silence with @unchecked.
  public func enableSkan(
    mapper: ConversionValueMapper,
    currency: String?,
    installationId: String,
    reporter: any SkanReporter,
    configVersion: Int = 0
  ) {
    skan = SkanStateMachine(
      store: store, clock: clock, installationId: installationId,
      mapper: mapper, currency: currency, configVersion: configVersion)
    skanReporter = reporter
    reporter.register()
  }

  /// Feeds SKAN and reports if the value moved.
  ///
  /// `confirm` runs only after the reporter returns without throwing. A device
  /// that recorded a value it never sent would refuse to send it again, and
  /// that window would report nothing for the rest of its life.
  public func recordSkan(
    event: String?, revenueMicros: String? = nil, revenueCurrency: String? = nil
  ) async {
    // Apple's conversion value is a measurement like any other, so it is gated
    // like any other. Reporting revenue for a user who has not consented is a
    // compliance failure, not a parity detail.
    if forgotten || (config.requireConsent && !consent) { return }
    guard let skan, let reporter = skanReporter else { return }
    guard let update = skan.record(
      event: event, revenueMicros: revenueMicros, revenueCurrency: revenueCurrency)
    else { return }

    do {
      try await reporter.update(
        fine: update.fineValue, coarse: update.coarseValue, lockWindow: update.lockWindow)
      skan.confirm(update)
    } catch {
      skan.abandon(update)
      onError("skan.update", error)
    }
  }

  /// Registers the device's push token for uninstall measurement (#26).
  ///
  /// The host app owns push registration: the SDK never asks for the
  /// notification permission and never displays anything. Pass the token your
  /// push library already gives you, on every launch — the OS can rotate it at
  /// any time, and a stale token is the one thing that makes uninstall
  /// measurement report churn that did not happen.
  ///
  /// `provider` should be passed explicitly by an iOS app using Firebase
  /// Messaging: that app holds an FCM token, and probing it against APNs would
  /// look like an uninstall on every device.
  public func setPushToken(_ token: String?, provider: String? = nil) {
    guard !forgotten else { return }
    guard let token else {
      pushToken = nil
      pushProvider = nil
      return
    }
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isValidPushToken(trimmed) else {
      pushToken = nil
      pushProvider = nil
      onError("push.setPushToken", IngestError(status: 400))
      return
    }
    pushToken = trimmed
    pushProvider = provider ?? (config.platform == "android" ? "fcm" : "apns")
  }


  public func setUserId(_ id: String?) {
    customerUserId = id
    if let id {
      store.set(id, forKey: USER_ID_KEY)
    } else {
      store.removeObject(forKey: USER_ID_KEY)
    }
  }

  /// Erasure. NOTE: this clears only what lives in the `KeyValueStore`. The
  /// durable device id lives in platform secure storage and is wiped by the
  /// platform layer — a caller that invokes only this leaves the identifier
  /// behind, which is an erasure that does not erase (spec §5).
  public func forgetMe() {
    forgotten = true
    queue.clear()
    sessions.reset()
    consent = false
    consentData = nil
    pushToken = nil
    pushProvider = nil
    customerUserId = nil
    for key in [CONSENT_KEY, CONSENT_DATA_KEY, SESSION_STATE_KEY, USER_ID_KEY] {
      store.removeObject(forKey: key)
    }
  }

  public func notifyForeground() {
    let events = sessions.handleForeground()
    for event in events {
      track(event.name, properties: event.properties, type: "session")
    }
    // A conversion rule may name "session", and the RN SDK has always fed it.
    // The generic name rather than session_start/session_end keeps one rule
    // matching both a cold start and a return.
    if !events.isEmpty {
      Task { [weak self] in await self?.recordSkan(event: "session") }
    }
  }

  public func notifyBackground() {
    if let event = sessions.handleBackground() {
      track(event.name, properties: event.properties, type: "session")
    }
  }

  public func pendingEventIds() -> [String] {
    queue.peek(Int.max).map(\.id)
  }

  /// Test surface: the ids alone cannot say what a field carries.
  public func pendingEvents() -> [ClientEvent] { queue.peek(Int.max) }

  /// Uploads buffered events. No-op when empty, re-entrancy guarded, and never
  /// throws — a timer-driven call is unawaited, so a transient failure simply
  /// leaves the batch buffered for the next attempt.
  public func flush() async {
    guard let transport else { return }
    if flushing || queue.size == 0 || clock.nowMs() < backoffUntilMs { return }
    flushing = true
    defer { flushing = false }

    // Clamped to the wire's limit, not trusted. The server answers 400 for a
    // larger batch and a 400 is not retryable, so an app that set 200 would
    // have every batch rejected and then re-sent one event at a time by the
    // poison-isolation path: nothing lost, and every flush costing 1 + N
    // requests forever. The constant said 100 and enforced nothing until now.
    let events = queue.peek(min(config.batchSize, MAX_BATCH_SIZE))
    if events.isEmpty { return }

    do {
      try await transport.send(events)
    } catch {
      if let ingest = error as? IngestError, !ingest.isRetryable {
        // Poison payload. Ingest parses a batch as a whole and answers one 400
        // for all of it, so the offender has to be found rather than the batch
        // discarded. A 4xx is not an outage, so it does not arm the backoff.
        onError("flush.poison", error)
        await isolatePoison(events, transport)
      } else {
        // Transient (network, 5xx, 429): keep the batch and back off, so a
        // fleet recovering from an outage does not retry in lockstep.
        onError("flush.transport", error)
        armBackoff()
      }
      return
    }

    queue.ack(events)
    consecutiveFailures = 0
    backoffUntilMs = 0
  }

  /// Re-sends a rejected batch one event at a time so a single poison event is
  /// dropped while the rest are delivered or kept. Stops at the first transient
  /// error, so a network drop mid-isolation cannot turn deliverable events into
  /// dropped ones.
  private func isolatePoison(_ events: [ClientEvent], _ transport: any EventTransport) async {
    for event in events {
      do {
        try await transport.send([event])
        queue.ack([event])
      } catch {
        guard let ingest = error as? IngestError, !ingest.isRetryable else { return }
        queue.ack([event])
        onDrop([event])
      }
    }
  }

  private func armBackoff() {
    consecutiveFailures += 1
    let delay = backoffDelayMs(
      failures: consecutiveFailures, baseMs: config.retryBaseMs,
      capMs: config.retryCapMs, random: random())
    backoffUntilMs = clock.nowMs() + Int64(delay)
  }

  /// Test surface: the `flush/` vectors assert that a 4xx leaves this at zero.
  public func consecutiveFailureCount() -> Int { consecutiveFailures }
}

/// A command submitted to the engine through the ordered ingress.
public enum Command: Sendable {
  case track(name: String, properties: [String: AdvenueValue]?, type: String)
  case setConsent(Bool)
  case setUserId(String?)
  case forgetMe
  case foreground
  case background
  case flush
  case setIdentity(idfa: String?, vendorId: String?, appInstanceId: String?)
  case setAppInstanceId(String?)
  case setConsentData(Consent?)
  case setPushToken(token: String?, provider: String?)
  case setDeviceInfo([String: AdvenueValue])
  case recordSkan(event: String?, revenueMicros: String?, revenueCurrency: String?)
  case enableSkan(
    mapper: ConversionValueMapper, currency: String?, installationId: String,
    reporter: any SkanReporter, configVersion: Int)
  case trackInstall(
    adservicesToken: String?, attestation: AttestationResult?, attestationChallenge: String?)
}

/// The ordered ingress: a synchronous, non-blocking `submit` feeding one
/// consumer task.
///
/// Why a stream and not `Task { await engine.track(...) }` per call: an
/// unstructured `Task` does not preserve submission order, so an event could
/// overtake its own `session_start`. `continuation.yield` is synchronous,
/// non-blocking and ordered.
public final class CommandPipe: @unchecked Sendable {
  private let continuation: AsyncStream<Command>.Continuation
  private var consumer: Task<Void, Never>?

  public init(
    engine: AdvenueEngine,
    onError: @escaping @Sendable (String, any Error) -> Void = { _, _ in }
  ) {
    // Unbounded on purpose: .bufferingNewest would silently DROP attribution
    // events, and the real bound is applied downstream by the queue's cap.
    let (stream, continuation) = AsyncStream<Command>.makeStream(
      of: Command.self, bufferingPolicy: .unbounded)
    self.continuation = continuation
    self.consumer = Task {
      for await command in stream {
        // Each command is handled inside its own do/catch. An unhandled throw
        // would END this task: the stream would stop draining, submit() would
        // keep yielding into a growing buffer, nothing would send, nothing
        // would error, and the app would not crash — attribution would simply
        // stop. Silent total failure is the worst mode available, so this loop
        // must be unkillable.
        do {
          try await Self.handle(command, engine)
        } catch {
          onError("engine.command", error)
        }
      }
    }
  }

  private static func handle(_ command: Command, _ engine: AdvenueEngine) async throws {
    switch command {
    case .track(let name, let properties, let type):
      await engine.track(name, properties: properties, type: type)
    case .setConsent(let granted):
      await engine.setConsent(granted)
    case .setUserId(let id):
      await engine.setUserId(id)
    case .forgetMe:
      await engine.forgetMe()
    case .foreground:
      await engine.notifyForeground()
    case .background:
      await engine.notifyBackground()
    case .flush:
      await engine.flush()
    case .setIdentity(let idfa, let vendorId, let appInstanceId):
      await engine.setIdentity(idfa: idfa, vendorId: vendorId, appInstanceId: appInstanceId)
    case .setAppInstanceId(let id):
      await engine.setAppInstanceId(id)
    case .trackInstall(let token, let attestation, let challenge):
      await engine.trackInstall(
        adservicesToken: token, attestation: attestation, attestationChallenge: challenge)
    case .setConsentData(let consent):
      await engine.setConsentData(consent)
    case .setPushToken(let token, let provider):
      await engine.setPushToken(token, provider: provider)
    case .setDeviceInfo(let info):
      await engine.setDeviceInfo(info)
    case .recordSkan(let event, let micros, let currency):
      await engine.recordSkan(event: event, revenueMicros: micros, revenueCurrency: currency)
    case .enableSkan(let mapper, let currency, let installationId, let reporter, let version):
      await engine.enableSkan(
        mapper: mapper, currency: currency, installationId: installationId,
        reporter: reporter, configVersion: version)
    }
  }

  /// Synchronous, non-blocking and **ordered** — this is why the ingress is a
  /// stream rather than a fresh Task per call.
  public func submit(_ command: Command) {
    continuation.yield(command)
  }

  public func shutdown() {
    continuation.finish()
    consumer = nil
  }
}

/// Decodes the persisted DMA consent. Public because the platform facade
/// answers `consentData()` from the same bytes the engine loads — two decoders
/// would be two chances to disagree about what the device consented to.
public func readPersistedConsentData(_ store: KeyValueStore) -> Consent? {
  guard let raw = store.string(forKey: CONSENT_DATA_KEY), let data = raw.data(using: .utf8)
  else { return nil }
  return try? JSONDecoder().decode(Consent.self, from: data)
}

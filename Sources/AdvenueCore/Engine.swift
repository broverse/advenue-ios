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
    event.properties = properties
    queue.enqueue(event)
    return true
  }

  public func setConsent(_ granted: Bool) {
    consent = granted
    store.set(granted ? "granted" : "denied", forKey: CONSENT_KEY)
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
    customerUserId = nil
    for key in [CONSENT_KEY, CONSENT_DATA_KEY, SESSION_STATE_KEY, USER_ID_KEY] {
      store.removeObject(forKey: key)
    }
  }

  public func notifyForeground() {
    for event in sessions.handleForeground() {
      track(event.name, properties: event.properties, type: "session")
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

  /// Uploads buffered events. No-op when empty, re-entrancy guarded, and never
  /// throws — a timer-driven call is unawaited, so a transient failure simply
  /// leaves the batch buffered for the next attempt.
  public func flush() async {
    guard let transport else { return }
    if flushing || queue.size == 0 || clock.nowMs() < backoffUntilMs { return }
    flushing = true
    defer { flushing = false }

    let events = queue.peek(config.batchSize)
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

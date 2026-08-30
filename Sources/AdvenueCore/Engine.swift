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

  public init(
    apiKey: String, platform: String, deviceId: String, installationId: String? = nil,
    appVersion: String? = nil, osVersion: String? = nil, sdkVersion: String? = nil,
    requireConsent: Bool = false, sessionWindowMs: Int64 = DEFAULT_SESSION_WINDOW_MS,
    maxQueueSize: Int = 10_000
  ) {
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

  private var consent: Bool
  private var forgotten = false
  private var customerUserId: String?

  public init(
    config: EngineConfig,
    store: KeyValueStore,
    clock: Clock,
    scheduler: Scheduler,
    uuid: UUIDSource,
    onError: @escaping @Sendable (String, any Error) -> Void = { _, _ in }
  ) {
    self.config = config
    self.store = store
    self.clock = clock
    self.uuid = uuid
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
}

/// A command submitted to the engine through the ordered ingress.
public enum Command: Sendable {
  case track(name: String, properties: [String: AdvenueValue]?, type: String)
  case setConsent(Bool)
  case setUserId(String?)
  case forgetMe
  case foreground
  case background
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

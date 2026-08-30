import Foundation

public let SESSION_STATE_KEY = "advenue.session"
public let DEFAULT_SESSION_WINDOW_MS: Int64 = 1_800_000  // 30 minutes

/// A session lifecycle event. Values are numbers, strings and bools only.
public struct SessionEvent: Equatable, Sendable {
  public let name: String
  public let properties: [String: AdvenueValue]
}

/// Persisted state. Field names match the TypeScript shape exactly — the RN
/// inversion reads state this SDK wrote and vice versa, and a renamed field
/// would silently restart every device's session numbering.
struct SessionState: Codable {
  var sessionId: String
  var sessionNumber: Int
  var lastBackgroundAt: Int64?
  var subSessionCount: Int
  var activeStart: Int64?
  var firstForegroundAt: Int64
  var timeSpentMs: Int64
}

/// Platform-agnostic session state machine. Pure: it persists state and
/// returns the events to emit; enqueueing is the caller's job.
public final class SessionTracker {
  private var cached: SessionState?
  private let store: KeyValueStore
  private let clock: Clock
  private let windowMs: Int64
  private let uuid: UUIDSource

  public init(store: KeyValueStore, clock: Clock, windowMs: Int64, uuid: UUIDSource) {
    self.store = store
    self.clock = clock
    self.windowMs = windowMs
    self.uuid = uuid
  }

  /// Drops the in-memory cache so a wiped store cannot be resurrected by a
  /// later lifecycle call (GDPR erasure).
  public func reset() { cached = nil }

  private func load() -> SessionState? {
    if let cached { return cached }
    guard let raw = store.string(forKey: SESSION_STATE_KEY),
      let data = raw.data(using: .utf8),
      let parsed = try? JSONDecoder().decode(SessionState.self, from: data)
    else { return nil }
    cached = parsed
    return parsed
  }

  private func save(_ state: SessionState) {
    cached = state
    guard let data = try? EventEncoding.canonicalEncoder().encode(state) else { return }
    store.set(String(decoding: data, as: UTF8.self), forKey: SESSION_STATE_KEY)
  }

  /// Foreground transition, including cold start. Returns the events to emit:
  /// none for a sub-session, one `session_start` for a new session, or a
  /// synthetic `session_end` FOLLOWED BY the start when the previous session
  /// was still open — the OS killed the app before it could background. The
  /// order is load-bearing: a consumer must never see two sessions open.
  public func handleForeground() -> [SessionEvent] {
    let state = load()
    let now = clock.nowMs()
    let gap: Int64? = state?.lastBackgroundAt.map { now - $0 }

    if state == nil || gap == nil || gap! >= windowMs {
      let sessionNumber = (state?.sessionNumber ?? 0) + 1
      let sessionId = uuid.next()
      save(
        SessionState(
          sessionId: sessionId, sessionNumber: sessionNumber, lastBackgroundAt: nil,
          subSessionCount: 1, activeStart: now, firstForegroundAt: now, timeSpentMs: 0))

      let start = SessionEvent(
        name: "session_start",
        properties: [
          "sessionId": .string(sessionId),
          "sessionNumber": .int(sessionNumber),
          "subSession": .int(1),
          "isFirstSession": .bool(sessionNumber == 1),
          "timeSinceLastSessionMs": .int(Int(gap ?? 0)),
        ])

      if let prior = state, let activeStart = prior.activeStart {
        let killTime = prior.lastBackgroundAt ?? now
        let activeMs = max(0, killTime - activeStart)
        let end = SessionEvent(
          name: "session_end",
          properties: [
            "sessionId": .string(prior.sessionId),
            "sessionNumber": .int(prior.sessionNumber),
            "subSession": .int(prior.subSessionCount),
            "activeMs": .int(Int(activeMs)),
            "timeSpentMs": .int(Int(prior.timeSpentMs + activeMs)),
            "sessionLengthMs": .int(Int(max(0, killTime - prior.firstForegroundAt))),
            "synthetic": .bool(true),
          ])
        return [end, start]
      }
      return [start]
    }

    var updated = state!
    updated.subSessionCount += 1
    updated.activeStart = now
    save(updated)
    return []
  }

  /// Background transition. Emits a `session_end` carrying this sub-session's
  /// stretch (`activeMs`), the session's cumulative active time
  /// (`timeSpentMs`) and its wall-clock span (`sessionLengthMs`) — three
  /// different numbers a port is likely to collapse into one.
  public func handleBackground() -> SessionEvent? {
    guard var state = load(), let activeStart = state.activeStart else { return nil }
    let now = clock.nowMs()
    let activeMs = max(0, now - activeStart)
    let timeSpentMs = state.timeSpentMs + activeMs
    state.lastBackgroundAt = now
    state.activeStart = nil
    state.timeSpentMs = timeSpentMs
    save(state)
    return SessionEvent(
      name: "session_end",
      properties: [
        "sessionId": .string(state.sessionId),
        "sessionNumber": .int(state.sessionNumber),
        "subSession": .int(state.subSessionCount),
        "activeMs": .int(Int(activeMs)),
        "timeSpentMs": .int(Int(timeSpentMs)),
        "sessionLengthMs": .int(Int(max(0, now - state.firstForegroundAt))),
      ])
  }
}

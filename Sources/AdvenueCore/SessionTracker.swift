import Foundation

public let SESSION_STATE_KEY = "advenue.session"
public let DEFAULT_SESSION_WINDOW_MS: Int64 = 1_800_000  // 30 minutes
/// The heartbeat persists at most this often: it runs on every recorded event,
/// and a chatty app must not turn that into a storage write per event.
public let SESSION_HEARTBEAT_MIN_INTERVAL_MS: Int64 = 1_000

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
  /// The last moment the open sub-session was known to be alive (F-SDK-7).
  /// Absent in state written before it existed, which reads as "alive at
  /// activeStart".
  var lastActiveAt: Int64?
}

/// Platform-agnostic session state machine. Pure: it persists state and
/// returns the events to emit; enqueueing is the caller's job.
public final class SessionTracker {
  private var cached: SessionState?
  private let store: KeyValueStore
  private let clock: Clock
  private let windowMs: Int64
  private let uuid: UUIDSource
  /// True once THIS process opened the current sub-session (X-SDK-1). Never
  /// persisted: a relaunched process starts false, so its tracks and flushes
  /// before `handleForeground()` cannot keep the dead process's sub-session
  /// alive and move its kill time to the relaunch.
  private var ownsOpenSubSession = false

  public init(store: KeyValueStore, clock: Clock, windowMs: Int64, uuid: UUIDSource) {
    self.store = store
    self.clock = clock
    self.windowMs = windowMs
    self.uuid = uuid
  }

  /// Drops the in-memory cache so a wiped store cannot be resurrected by a
  /// later lifecycle call (GDPR erasure).
  public func reset() {
    cached = nil
    ownsOpenSubSession = false
  }

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

  /// Refreshes the open sub-session's last known activity. Called by the
  /// engine on every recorded event and every flush — the auto-flush timer is
  /// the foreground tick. It is what a relaunch after an OS kill measures the
  /// gap from, the role Adjust's `lastActivity` plays.
  ///
  /// A no-op until this process has run `handleForeground()`: only the process
  /// that opened the sub-session may extend it. Otherwise an event or flush in a
  /// relaunched process (iOS `didFinishLaunching` runs before
  /// `didBecomeActive`; push and background wakes) would stamp the killed
  /// sub-session alive "now" and count the dead time as active (X-SDK-1).
  public func heartbeat() {
    guard ownsOpenSubSession else { return }
    guard var state = load(), let activeStart = state.activeStart else { return }
    let now = clock.nowMs()
    if now - (state.lastActiveAt ?? activeStart) < SESSION_HEARTBEAT_MIN_INTERVAL_MS { return }
    state.lastActiveAt = now
    save(state)
  }

  /// Foreground transition, including cold start. Returns the events to emit,
  /// in order:
  ///
  /// - a synthetic `session_end` first when a sub-session was still open — the
  ///   OS killed the app before it could background. It is closed at its last
  ///   heartbeat, not at the relaunch: the time the app was dead is not active
  ///   time. A consumer must never see two sessions open, so it comes first.
  /// - then, measured from the background (or that kill time): nothing for a
  ///   sub-session inside the window, or a `session_start` for a new session.
  ///
  /// A kill is not a session boundary by itself (F-SDK-7). Adjust's rule — a
  /// new session only after the session interval of inactivity — applies to a
  /// relaunch exactly as it does to a return from the background.
  public func handleForeground() -> [SessionEvent] {
    let now = clock.nowMs()
    guard var state = load(), let activeStart = state.activeStart else {
      return resume(after: load(), now: now)
    }

    let killTime = min(now, max(activeStart, state.lastActiveAt ?? activeStart))
    let activeMs = max(0, killTime - activeStart)
    let timeSpentMs = state.timeSpentMs + activeMs
    let end = SessionEvent(
      name: "session_end",
      properties: [
        "sessionId": .string(state.sessionId),
        "sessionNumber": .int(state.sessionNumber),
        "subSession": .int(state.subSessionCount),
        "activeMs": .int(Int(activeMs)),
        "timeSpentMs": .int(Int(timeSpentMs)),
        "sessionLengthMs": .int(Int(max(0, killTime - state.firstForegroundAt))),
        "synthetic": .bool(true),
      ])
    state.lastBackgroundAt = killTime
    state.activeStart = nil
    state.lastActiveAt = nil
    state.timeSpentMs = timeSpentMs
    return [end] + resume(after: state, now: now)
  }

  /// The foreground decision once no sub-session is open.
  private func resume(after state: SessionState?, now: Int64) -> [SessionEvent] {
    let gap: Int64? = state?.lastBackgroundAt.map { now - $0 }

    if state == nil || gap == nil || gap! >= windowMs {
      let sessionNumber = (state?.sessionNumber ?? 0) + 1
      let sessionId = uuid.next()
      save(
        SessionState(
          sessionId: sessionId, sessionNumber: sessionNumber, lastBackgroundAt: nil,
          subSessionCount: 1, activeStart: now, firstForegroundAt: now, timeSpentMs: 0))
      ownsOpenSubSession = true

      return [
        SessionEvent(
          name: "session_start",
          properties: [
            "sessionId": .string(sessionId),
            "sessionNumber": .int(sessionNumber),
            "subSession": .int(1),
            "isFirstSession": .bool(sessionNumber == 1),
            "timeSinceLastSessionMs": .int(Int(gap ?? 0)),
          ])
      ]
    }

    var updated = state!
    updated.subSessionCount += 1
    updated.activeStart = now
    updated.lastActiveAt = nil
    save(updated)
    ownsOpenSubSession = true
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
    state.lastActiveAt = nil
    state.timeSpentMs = timeSpentMs
    save(state)
    ownsOpenSubSession = false
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

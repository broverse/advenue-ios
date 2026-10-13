import Foundation
import XCTest

@testable import AdvenueCore

/// Throws the scripted errors in order, then succeeds.
actor ErrorScriptTransport: EventTransport {
  private var errors: [any Error]
  private(set) var calls = 0
  init(_ errors: [any Error]) { self.errors = errors }
  func send(_ events: [ClientEvent]) async throws {
    calls += 1
    if !errors.isEmpty { throw errors.removeFirst() }
  }
}

final class SandboxTests: XCTestCase {
  private func engine(_ store: MemoryStore, _ clock: MutableClock, _ transport: ErrorScriptTransport)
    -> AdvenueEngine
  {
    AdvenueEngine(
      config: EngineConfig(apiKey: "apk_test", platform: "ios", deviceId: "d1"),
      store: store, clock: clock, scheduler: RecordingScheduler(),
      uuid: SequentialUUIDs(prefix: "ev"), transport: transport)
  }

  /// Spec 2 §7.2: the quota resets at a known instant, so the SDK waits for it
  /// instead of backing off exponentially, and keeps the events.
  func testQuotaPausesUntilResetAtWithoutCountingAFailure() async {
    let clock = MutableClock()
    clock.ms = 1_000_000
    let transport = ErrorScriptTransport([IngestError(status: 429, quotaResetAtMs: 5_000_000)])
    let e = engine(MemoryStore(), clock, transport)
    await e.track("probe")
    await e.flush()
    clock.ms = 4_999_999
    await e.flush()
    var calls = await transport.calls
    XCTAssertEqual(calls, 1, "nothing is sent before resetAt")
    let failures = await e.consecutiveFailureCount()
    XCTAssertEqual(failures, 0, "a spent quota is not an outage")
    clock.ms = 5_000_000
    await e.flush()
    calls = await transport.calls
    XCTAssertEqual(calls, 2)
    let pending = await e.pendingEventIds()
    XCTAssertTrue(pending.isEmpty)
  }

  /// Spec 2 §7.2 (P3): an old server would file sandbox events as production.
  func testUnsupportedServerStopsUploadsForTheProcessAndKeepsTheEvents() async {
    let clock = MutableClock()
    clock.ms = 1_000_000
    let transport = ErrorScriptTransport([SandboxUnsupportedError(.capabilityMissing)])
    let e = engine(MemoryStore(), clock, transport)
    await e.track("probe")
    await e.flush()
    clock.ms += 3_600_000
    await e.flush()
    let calls = await transport.calls
    XCTAssertEqual(calls, 1)
    let disabled = await e.uploadsAreDisabled()
    XCTAssertTrue(disabled)
    let pending = await e.pendingEventIds()
    XCTAssertEqual(pending.count, 1, "events stay on the device")
  }

  func testTheQuotaErrorSaysWhenUploadsResume() {
    let error = IngestError(status: 429, quotaResetAtMs: 1_760_400_000_000)
    XCTAssertEqual(
      "\(error)",
      "Advenue: sandbox limit reached for today; uploads resume at \(EventEncoding.iso8601(ms: 1_760_400_000_000)).")
    XCTAssertTrue(error.isRetryable)
  }

  func testTheUnsupportedErrorUsesTheSpecWording() {
    XCTAssertEqual(
      "\(SandboxUnsupportedError(.responseMismatch))",
      "Advenue: this server does not support sandbox; events are kept on the device and not sent.")
  }

  /// Spec 2 §7.2: a changed environment clears the queue and the install flag
  /// so the new environment records its own install; ids are kept.
  func testEnvironmentChangeClearsQueueAndInstallFlag() {
    let store = MemoryStore()
    store.preload(QUEUE_KEY, #"[{"deviceId":"d1","id":"e1","name":"x","platform":"ios","timestamp":"2026-01-01T00:00:00.000Z","type":"custom"}]"#)
    store.preload(INSTALL_SENT_KEY, "1")
    store.preload(ENVIRONMENT_KEY, "production")
    let dropped = reconcileEnvironment(.sandbox, store: store, scheduler: RecordingScheduler())
    XCTAssertEqual(dropped, 1)
    XCTAssertNil(store.raw(INSTALL_SENT_KEY))
    XCTAssertEqual(store.raw(ENVIRONMENT_KEY), "sandbox")
    XCTAssertEqual(store.raw(QUEUE_KEY), "[]")
  }

  func testUnchangedEnvironmentTouchesNothing() {
    let store = MemoryStore()
    store.preload(INSTALL_SENT_KEY, "1")
    XCTAssertNil(reconcileEnvironment(.production, store: store, scheduler: RecordingScheduler()))
    XCTAssertEqual(store.raw(INSTALL_SENT_KEY), "1")
    store.preload(ENVIRONMENT_KEY, "sandbox")
    XCTAssertNil(reconcileEnvironment(.sandbox, store: store, scheduler: RecordingScheduler()))
  }

  /// An SDK upgraded from a release without the option ran production.
  func testAbsentRecordIsProduction() {
    let store = MemoryStore()
    store.preload(INSTALL_SENT_KEY, "1")
    XCTAssertEqual(reconcileEnvironment(.sandbox, store: store, scheduler: RecordingScheduler()), 0)
    XCTAssertNil(store.raw(INSTALL_SENT_KEY))
  }

  // MARK: ordering and isolation (final review)

  /// Records the order of writes and can "crash" on a chosen key.
  private final class OrderedStore: KeyValueStore, @unchecked Sendable {
    struct Crash: Error {}
    let inner: MemoryStore
    let crashOnSet: String?
    private(set) var writes: [String] = []
    private(set) var crashed = false
    init(_ inner: MemoryStore, crashOnSet: String? = nil) {
      self.inner = inner
      self.crashOnSet = crashOnSet
    }
    func string(forKey key: String) -> String? { inner.string(forKey: key) }
    func set(_ value: String, forKey key: String) {
      if key == crashOnSet { crashed = true }  // the process dies here
      if crashed { return }
      writes.append("set:\(key)")
      inner.set(value, forKey: key)
    }
    func removeObject(forKey key: String) {
      if crashed { return }
      writes.append("remove:\(key)")
      inner.removeObject(forKey: key)
    }
  }

  private static let oldQueue =
    #"[{"deviceId":"d1","id":"e1","name":"x","platform":"ios","timestamp":"2026-01-01T00:00:00.000Z","type":"custom"}]"#

  /// The new environment is recorded LAST: a kill before that leaves the old
  /// record, so the next launch clears again instead of uploading the old
  /// sandbox queue as production.
  func testEnvironmentKeyIsWrittenLast() {
    let inner = MemoryStore()
    inner.preload(QUEUE_KEY, Self.oldQueue)
    inner.preload(INSTALL_SENT_KEY, "1")
    inner.preload(ENVIRONMENT_KEY, "sandbox")
    let store = OrderedStore(inner)
    _ = reconcileEnvironment(.production, store: store, scheduler: RecordingScheduler())
    XCTAssertEqual(store.writes.last, "set:\(ENVIRONMENT_KEY)", "\(store.writes)")
    XCTAssertTrue(store.writes.contains("remove:\(INSTALL_SENT_KEY)"))
  }

  func testCrashBeforeTheEnvironmentKeyLeavesNothingToUploadAsProduction() {
    let inner = MemoryStore()
    inner.preload(QUEUE_KEY, Self.oldQueue)
    inner.preload(INSTALL_SENT_KEY, "1")
    inner.preload(ENVIRONMENT_KEY, "sandbox")
    let crashing = OrderedStore(inner, crashOnSet: ENVIRONMENT_KEY)
    _ = reconcileEnvironment(.production, store: crashing, scheduler: RecordingScheduler())
    XCTAssertTrue(crashing.crashed)
    XCTAssertEqual(inner.raw(ENVIRONMENT_KEY), "sandbox", "old record stays, so the change is seen again")
    XCTAssertEqual(inner.raw(QUEUE_KEY), "[]", "the old queue is already gone")
    XCTAssertNil(inner.raw(INSTALL_SENT_KEY))
    // Next launch: still a change, clears again, and records the key.
    XCTAssertEqual(reconcileEnvironment(.production, store: inner, scheduler: RecordingScheduler()), 0)
    XCTAssertEqual(inner.raw(ENVIRONMENT_KEY), "production")
  }

  /// Spec 2 §7.2: a spent quota seen while isolating a poison batch pauses
  /// until resetAt and is not a failure, exactly as in flush.
  func testQuotaDuringPoisonIsolationSetsBackoffWithoutCountingAFailure() async {
    let clock = MutableClock()
    clock.ms = 1_000_000
    let transport = ErrorScriptTransport([
      IngestError(status: 400), IngestError(status: 429, quotaResetAtMs: 5_000_000),
    ])
    let e = engine(MemoryStore(), clock, transport)
    await e.track("a")
    await e.track("b")
    await e.flush()
    var calls = await transport.calls
    XCTAssertEqual(calls, 2)
    let failures = await e.consecutiveFailureCount()
    XCTAssertEqual(failures, 0)
    clock.ms = 4_999_999
    await e.flush()
    calls = await transport.calls
    XCTAssertEqual(calls, 2, "paused until resetAt")
    clock.ms = 5_000_000
    await e.flush()
    calls = await transport.calls
    XCTAssertGreaterThan(calls, 2)
  }
}

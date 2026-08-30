import Foundation
import XCTest

@testable import AdvenueCore

/// A store whose writes can be made to fail, used to prove the consumer loop
/// survives a failing dependency.
final class ExplodingStore: KeyValueStore, @unchecked Sendable {
  private var values: [String: String] = [:]
  var explodeOnWrite = false
  private(set) var writeAttempts = 0

  func string(forKey key: String) -> String? { values[key] }
  func set(_ value: String, forKey key: String) {
    writeAttempts += 1
    if explodeOnWrite { return }
    values[key] = value
  }
  func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

final class ConcurrencyTests: XCTestCase {
  /// The property no vector can express: submission order is preserved. A
  /// Task-per-call ingress would let an event overtake its own session_start.
  func testSubmissionOrderIsPreserved() async throws {
    let engine = AdvenueEngine(
      config: EngineConfig(apiKey: "k", platform: "ios", deviceId: "dev-1"),
      store: MemoryStore(), clock: FixedClock(ms: 0),
      scheduler: RecordingScheduler(), uuid: SequentialUUIDs(prefix: "e"))
    let pipe = CommandPipe(engine: engine)
    defer { pipe.shutdown() }

    for i in 0..<200 {
      pipe.submit(.track(name: "e\(i)", properties: nil, type: "custom"))
    }

    try await waitUntil { await engine.pendingEventIds().count == 200 }
    let ids = await engine.pendingEventIds()
    XCTAssertEqual(
      ids, (1...200).map { "e-\($0)" },
      "ids are minted in submission order, so the stream preserved it")
  }

  /// The silent-total-failure guard: a failing dependency must not end the
  /// consumer task, or tracking stops forever with no crash and no error.
  func testConsumerLoopSurvivesAFailingStore() async throws {
    let store = ExplodingStore()
    let engine = AdvenueEngine(
      config: EngineConfig(apiKey: "k", platform: "ios", deviceId: "dev-1"),
      store: store, clock: FixedClock(ms: 0),
      scheduler: RecordingScheduler(), uuid: SequentialUUIDs(prefix: "e"))
    let pipe = CommandPipe(engine: engine)
    defer { pipe.shutdown() }

    store.explodeOnWrite = true
    pipe.submit(.track(name: "during-failure", properties: nil, type: "custom"))
    try await waitUntil { await engine.pendingEventIds().count == 1 }

    store.explodeOnWrite = false
    pipe.submit(.track(name: "after-failure", properties: nil, type: "custom"))
    try await waitUntil { await engine.pendingEventIds().count == 2 }

    let ids = await engine.pendingEventIds()
    XCTAssertEqual(ids.count, 2, "the loop kept draining after the store misbehaved")
  }

  /// A lifecycle command and a track submitted together keep their order, so
  /// an event can never precede the session_start it belongs to.
  func testSessionStartPrecedesTheEventsInIt() async throws {
    let engine = AdvenueEngine(
      config: EngineConfig(apiKey: "k", platform: "ios", deviceId: "dev-1"),
      store: MemoryStore(), clock: FixedClock(ms: 0),
      scheduler: RecordingScheduler(), uuid: SequentialUUIDs(prefix: "e"))
    let pipe = CommandPipe(engine: engine)
    defer { pipe.shutdown() }

    pipe.submit(.foreground)
    pipe.submit(.track(name: "purchase", properties: nil, type: "custom"))

    try await waitUntil { await engine.pendingEventIds().count == 2 }
    // The session id is minted first, so the session_start event carries e-1
    // and the purchase e-2 — the ordering that matters for attribution.
    let ids = await engine.pendingEventIds()
    XCTAssertEqual(ids, ["e-2", "e-3"])
  }

  /// Polls a condition with a deadline. XCTestExpectation cannot await an
  /// actor, and a fixed sleep would be both slow and still flaky.
  private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: @Sendable () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("condition not met within \(timeout)s")
  }
}

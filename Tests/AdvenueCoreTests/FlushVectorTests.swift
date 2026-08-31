import Foundation
import XCTest

@testable import AdvenueCore

/// Returns a scripted status per call and records the ids it was handed.
actor ScriptedTransport: EventTransport {
  private let statuses: [Int]
  private(set) var requests: [[String]] = []
  private var call = 0

  init(_ statuses: [Int]) { self.statuses = statuses }

  func send(_ events: [ClientEvent]) async throws {
    requests.append(events.map(\.id))
    let status = call < statuses.count ? statuses[call] : 204
    call += 1
    // 0 models a network error, which the real transport reports as 408.
    if status == 0 { throw IngestError(status: 408) }
    if status >= 300 { throw IngestError(status: status) }
  }
}

final class FlushVectorTests: XCTestCase {
  func testFlushVectors() async throws {
    let vectors = try loadVectors("flush")
    // A kind whose files went missing would otherwise pass vacuously: zero
    // vectors, zero failures, and the port inherits the silence.
    XCTAssertFalse(vectors.isEmpty, "no flush vectors bundled — run `pnpm conformance:sync`")

    for vector in vectors {
      let ids: [String] = try vector.value("queue")
      let batchSize: Int = try vector.value("batchSize")
      let statuses: [Int] = try vector.value("responses")
      let flushes: Int = vector.optional("flushes") ?? 1
      let expect: [String: Any] = try vector.value("expect")

      let store = MemoryStore()
      if !ids.isEmpty { store.preload(QUEUE_KEY, Self.seed(ids)) }

      let transport = ScriptedTransport(statuses)
      let dropped = Locked<[String]>([])
      let engine = AdvenueEngine(
        config: EngineConfig(
          apiKey: "apk_test", platform: "ios", deviceId: "d1", batchSize: batchSize),
        store: store, clock: FixedClock(ms: 1_700_000_000_000),
        scheduler: RecordingScheduler(), uuid: SequentialUUIDs(prefix: "x"),
        transport: transport,
        onDrop: { events in dropped.mutate { $0.append(contentsOf: events.map(\.id)) } })

      for _ in 0..<flushes { await engine.flush() }

      let requests = await transport.requests
      XCTAssertEqual(requests, expect["requests"] as? [[String]], "\(vector.file): requests")
      XCTAssertEqual(dropped.value, expect["dropped"] as? [String], "\(vector.file): dropped")
      let pending = await engine.pendingEventIds()
      XCTAssertEqual(pending, expect["pending"] as? [String], "\(vector.file): pending")
      let failures = await engine.consecutiveFailureCount()
      XCTAssertEqual(failures, expect["failuresAfter"] as? Int, "\(vector.file): failuresAfter")
    }
  }

  /// The persisted blob the queue loads from, matching what TypeScript writes.
  private static func seed(_ ids: [String]) -> String {
    let objects = ids.map {
      """
      {"deviceId":"d1","id":"\($0)","name":"e","platform":"ios",\
      "timestamp":"2026-01-01T00:00:00.000Z","type":"custom"}
      """
    }
    return "[\(objects.joined(separator: ","))]"
  }
}

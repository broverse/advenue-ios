import Foundation
import XCTest

@testable import AdvenueCore

final class ConsentVectorTests: XCTestCase {
  func testConsentVectors() async throws {
    let vectors = try loadVectors("consent")
    XCTAssertFalse(vectors.isEmpty, "consent vectors must be bundled")

    for vector in vectors {
      // One store and one transport for the whole vector: `relaunch` builds a
      // new engine over the same persisted state, as a cold start would.
      let store = MemoryStore()
      let transport = ScriptedTransport([])
      let requireConsent: Bool = try vector.value("requireConsent")
      func launch() -> AdvenueEngine {
        AdvenueEngine(
          config: EngineConfig(
            apiKey: "apk_live_conformance", platform: "ios", deviceId: "dev-1",
            installationId: "00000000-0000-4000-8000-000000000001",
            requireConsent: requireConsent),
          store: store, clock: FixedClock(ms: 0),
          scheduler: RecordingScheduler(), uuid: SequentialUUIDs(prefix: "event-uuid"),
          transport: transport)
      }
      var engine = launch()

      let steps: [[String: Any]] = try vector.value("steps")
      for (index, step) in steps.enumerated() {
        let context = "\(vector.file) step \(index)"
        switch step["op"] as! String {
        case "track":
          let accepted = await engine.track(step["name"] as! String)
          XCTAssertEqual(accepted, step["expectAccepted"] as! Bool, context)
        case "setConsent":
          await engine.setConsent(step["granted"] as! Bool)
        case "forgetMe":
          await engine.forgetMe()
        case "flush":
          await engine.flush()
        case "relaunch":
          engine = launch()
        case "seedQueue":
          store.preload(QUEUE_KEY, Self.seed(step["ids"] as! [String]))
        case "expectPending":
          let ids = await engine.pendingEventIds()
          XCTAssertEqual(ids.count, step["count"] as! Int, context)
        case "expectStoredQueue":
          XCTAssertEqual(Self.storedCount(store), step["count"] as! Int, context)
        case "expectRequests":
          let requests = await transport.requests
          XCTAssertEqual(requests.count, step["count"] as! Int, context)
        default:
          XCTFail("unknown consent op in \(context)")
        }
      }
    }
  }

  /// Events in the persisted queue blob; an absent blob is an empty queue.
  private static func storedCount(_ store: MemoryStore) -> Int {
    guard let raw = store.raw(QUEUE_KEY),
      let array = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any]
    else { return 0 }
    return array.count
  }

  /// A queue blob as an earlier launch would have persisted it.
  private static func seed(_ ids: [String]) -> String {
    let objects = ids.map {
      """
      {"deviceId":"dev-1","id":"\($0)","name":"e","platform":"ios",\
      "timestamp":"2026-01-01T00:00:00.000Z","type":"custom"}
      """
    }
    return "[\(objects.joined(separator: ","))]"
  }
}

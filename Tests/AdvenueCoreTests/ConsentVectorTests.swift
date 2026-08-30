import Foundation
import XCTest

@testable import AdvenueCore

final class ConsentVectorTests: XCTestCase {
  func testConsentVectors() async throws {
    let vectors = try loadVectors("consent")
    XCTAssertFalse(vectors.isEmpty, "consent vectors must be bundled")

    for vector in vectors {
      let engine = AdvenueEngine(
        config: EngineConfig(
          apiKey: "apk_live_conformance", platform: "ios", deviceId: "dev-1",
          installationId: "00000000-0000-4000-8000-000000000001",
          requireConsent: try vector.value("requireConsent")),
        store: MemoryStore(), clock: FixedClock(ms: 0),
        scheduler: RecordingScheduler(), uuid: SequentialUUIDs(prefix: "event-uuid"))

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
        case "expectPending":
          let ids = await engine.pendingEventIds()
          XCTAssertEqual(ids.count, step["count"] as! Int, context)
        default:
          XCTFail("unknown consent op in \(context)")
        }
      }
    }
  }
}

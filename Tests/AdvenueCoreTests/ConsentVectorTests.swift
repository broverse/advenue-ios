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
      let clock = MutableClock()
      var launches = 0
      // Ids are unique per launch: a relaunch that minted a new install would
      // otherwise reuse the first launch's ids and pass a same-id check.
      func launch() -> AdvenueEngine {
        launches += 1
        return AdvenueEngine(
          config: EngineConfig(
            apiKey: "apk_live_conformance", platform: "ios", deviceId: "dev-1",
            installationId: "00000000-0000-4000-8000-000000000001",
            requireConsent: requireConsent),
          store: store, clock: clock,
          scheduler: RecordingScheduler(),
          uuid: SequentialUUIDs(prefix: "launch\(launches)-uuid"),
          transport: transport)
      }
      var engine = launch()
      var remembered: (id: String, timestamp: String)?

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
        case "trackInstall":
          let accepted = await engine.trackInstall(adservicesToken: nil)
          XCTAssertEqual(accepted, step["expectAccepted"] as! Bool, context)
        case "setUserId":
          await engine.setUserId(step["id"] as? String)
        case "setAdvertisingId":
          await engine.setAdvertisingIdentity(
            idfa: step["id"] as? String, vendorId: nil, limitAdTracking: nil)
        case "advanceClock":
          clock.ms += Int64(step["ms"] as! Int)
        case "rememberPendingInstall":
          let installs = await engine.pendingEvents().filter { $0.type == "install" }
          XCTAssertEqual(installs.count, 1, context)
          if let install = installs.first { remembered = (install.id, install.timestamp) }
        case "expectDeferredInstall":
          let raw = store.raw(INSTALL_DEFERRED_KEY)
          XCTAssertEqual(raw != nil, step["present"] as! Bool, context)
          guard let raw,
            let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
          else { break }
          XCTAssertEqual(object["type"] as? String, "install", context)
          if let remembered {
            XCTAssertEqual(object["id"] as? String, remembered.id, context)
            XCTAssertEqual(object["timestamp"] as? String, remembered.timestamp, context)
          }
          for field in (step["absentFields"] as? [String]) ?? [] {
            XCTAssertNil(object[field], "\(context): \(field) kept on the device")
          }
          XCTAssertNotEqual(store.raw(INSTALL_SENT_KEY), "1", context)
        case "expectSentInstalls":
          let installs = await transport.sent.filter { $0.type == "install" }
          XCTAssertEqual(installs.count, step["count"] as! Int, context)
          if let remembered {
            for install in installs {
              XCTAssertEqual(install.id, remembered.id, context)
              XCTAssertEqual(install.timestamp, remembered.timestamp, context)
            }
          }
          if let userId = step["userId"] as? String {
            XCTAssertEqual(installs.last?.customerUserId, userId, context)
          }
          if let advertisingId = step["advertisingId"] as? String {
            XCTAssertEqual(installs.last?.idfa, advertisingId, context)
          }
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

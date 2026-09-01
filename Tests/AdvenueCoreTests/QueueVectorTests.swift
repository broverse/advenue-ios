import Foundation
import XCTest

@testable import AdvenueCore

/// Vector JSON to the SDK's closed property type.
///
/// `NSNumber` is the trap: JSONSerialization hands back one object for every
/// number, so `3` and `3.0` are told apart only by its objCType. Reading that
/// wrong here would make the test agree with a decoder that changed the type.
func advenueValue(_ raw: Any) -> AdvenueValue {
  switch raw {
  case is NSNull: return .null
  case let v as String: return .string(v)
  case let v as [Any]: return .array(v.map(advenueValue))
  case let v as [String: Any]: return .object(advenueValues(v))
  case let v as NSNumber:
    if CFGetTypeID(v) == CFBooleanGetTypeID() { return .bool(v.boolValue) }
    let type = String(cString: v.objCType)
    return type == "d" || type == "f" ? .double(v.doubleValue) : .int(v.intValue)
  default: return .null
  }
}

func advenueValues(_ raw: [String: Any]) -> [String: AdvenueValue] {
  raw.mapValues(advenueValue)
}

final class QueueVectorTests: XCTestCase {
  private func event(_ id: String) -> ClientEvent {
    ClientEvent(
      id: id, deviceId: "d", type: "custom", name: "e",
      timestamp: "1970-01-01T00:00:00.000Z", platform: "ios")
  }

  func testQueueVectors() throws {
    let vectors = try loadVectors("queue")
    XCTAssertFalse(vectors.isEmpty, "queue vectors must be bundled")

    for vector in vectors {
      let store = MemoryStore()
      if let preload: String = vector.optional("preloadRaw") {
        store.preload(QUEUE_KEY, preload)
      }
      let scheduler = RecordingScheduler()
      let maxSize: Int = try vector.value("maxSize")
      // `var`, because the `reload` op replaces it — see that case.
      var queue = EventQueue(store: store, maxSize: maxSize, scheduler: scheduler)

      func persistedIds() -> [String]? {
        guard let raw = store.raw(QUEUE_KEY), let data = raw.data(using: .utf8) else { return nil }
        let decoded = try? JSONDecoder().decode([ClientEvent].self, from: data)
        return decoded?.map(\.id)
      }

      let steps: [[String: Any]] = try vector.value("steps")
      for (index, step) in steps.enumerated() {
        let context = "\(vector.file) step \(index) (\(step["op"] ?? "?"))"
        switch step["op"] as! String {
        case "enqueue":
          if let ids = step["ids"] as? [String] {
            for id in ids { queue.enqueue(event(id)) }
          } else {
            // The richer form: an event with a payload. The id-only form above
            // is what the other four vectors use, and is why nothing caught a
            // reload path that dropped properties.
            for raw in step["events"] as! [[String: Any]] {
              var e = event(raw["id"] as! String)
              e.properties = advenueValues(raw["properties"] as! [String: Any])
              queue.enqueue(e)
            }
          }
        case "reload":
          // A fresh queue over the same store: exactly what a process restart
          // does, and the only path on which the decoder runs at all.
          queue = EventQueue(store: store, maxSize: maxSize, scheduler: scheduler)
        case "ack":
          queue.ack((step["ids"] as! [String]).map(event))
        case "clear":
          queue.clear()
        case "runScheduled":
          scheduler.runAll()
        case "expectPeek":
          XCTAssertEqual(
            queue.peek(step["max"] as! Int).map(\.id), step["ids"] as! [String], context)
        case "expectPeekEvents":
          let expected = step["events"] as! [[String: Any]]
          let actual = queue.peek(step["max"] as! Int)
          XCTAssertEqual(actual.map(\.id), expected.map { $0["id"] as! String }, context)
          for (event, want) in zip(actual, expected) {
            // Equality, not merely non-empty: a decoder that turned 3 into 3.0
            // would restore "some properties" and silently change the wire.
            XCTAssertEqual(
              event.properties, advenueValues(want["properties"] as! [String: Any]),
              "\(context) — properties for \(event.id)")
          }
        case "expectPersisted":
          XCTAssertEqual(persistedIds(), step["ids"] as? [String], context)
        case "expectScheduled":
          XCTAssertEqual(scheduler.count, step["count"] as! Int, context)
        default:
          XCTFail("unknown queue op in \(context)")
        }
      }
    }
  }
}

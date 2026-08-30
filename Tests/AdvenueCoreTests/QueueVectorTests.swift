import Foundation
import XCTest

@testable import AdvenueCore

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
      let queue = EventQueue(store: store, maxSize: maxSize, scheduler: scheduler)

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
          for id in step["ids"] as! [String] { queue.enqueue(event(id)) }
        case "ack":
          queue.ack((step["ids"] as! [String]).map(event))
        case "clear":
          queue.clear()
        case "runScheduled":
          scheduler.runAll()
        case "expectPeek":
          XCTAssertEqual(
            queue.peek(step["max"] as! Int).map(\.id), step["ids"] as! [String], context)
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

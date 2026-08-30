import Foundation

@testable import AdvenueCore

/// In-memory store. Not thread-safe by design — the engine confines it to one
/// task, and a lock here would hide a violation of that rather than prevent one.
final class MemoryStore: KeyValueStore, @unchecked Sendable {
  private var values: [String: String] = [:]

  func string(forKey key: String) -> String? { values[key] }
  func set(_ value: String, forKey key: String) { values[key] = value }
  func removeObject(forKey key: String) { values.removeValue(forKey: key) }

  func raw(_ key: String) -> String? { values[key] }
  func preload(_ key: String, _ value: String) { values[key] = value }
}

/// Runs scheduled work only when told to, so the persist debounce is
/// observable without waiting for it.
final class RecordingScheduler: Scheduler, @unchecked Sendable {
  private var pending: [CancelToken: () -> Void] = [:]
  private var next: CancelToken = 1

  var count: Int { pending.count }

  func schedule(afterMs: Int, _ work: @escaping () -> Void) -> CancelToken {
    let token = next
    next += 1
    pending[token] = work
    return token
  }

  func cancel(_ token: CancelToken) { pending.removeValue(forKey: token) }

  func runAll() {
    let work = Array(pending.values)
    pending.removeAll()
    for item in work { item() }
  }
}

struct FixedClock: Clock {
  let ms: Int64
  func nowMs() -> Int64 { ms }
}

/// A clock the test moves by hand.
final class MutableClock: Clock, @unchecked Sendable {
  var ms: Int64 = 0
  func nowMs() -> Int64 { ms }
}

final class SequentialUUIDs: UUIDSource, @unchecked Sendable {
  private var n = 0
  private let prefix: String
  init(prefix: String) { self.prefix = prefix }
  func next() -> String {
    n += 1
    return "\(prefix)-\(n)"
  }
}

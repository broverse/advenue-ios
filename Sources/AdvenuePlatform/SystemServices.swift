import AdvenueCore
import Foundation

public struct SystemClock: Clock {
  public init() {}
  public func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

public struct SystemUUIDs: UUIDSource {
  public init() {}
  public func next() -> String { UUID().uuidString.lowercased() }
}

/// Real deferred execution.
///
/// Satisfies `Scheduler`'s isolation contract by construction: work is
/// dispatched onto one serial queue, so every scheduled callback runs in the
/// same domain as every other. The queue's persist debounce is the only user.
public final class TimerScheduler: Scheduler, @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.advenue.sdk.scheduler")
  private var items: [CancelToken: DispatchWorkItem] = [:]
  private var next: CancelToken = 1
  private let lock = NSLock()

  public init() {}

  public func schedule(afterMs: Int, _ work: @escaping () -> Void) -> CancelToken {
    lock.lock()
    let token = next
    next += 1
    lock.unlock()

    let item = DispatchWorkItem { [weak self] in
      self?.forget(token)
      work()
    }
    lock.lock()
    items[token] = item
    lock.unlock()
    queue.asyncAfter(deadline: .now() + .milliseconds(afterMs), execute: item)
    return token
  }

  public func cancel(_ token: CancelToken) {
    lock.lock()
    let item = items.removeValue(forKey: token)
    lock.unlock()
    item?.cancel()
  }

  private func forget(_ token: CancelToken) {
    lock.lock()
    items.removeValue(forKey: token)
    lock.unlock()
  }
}

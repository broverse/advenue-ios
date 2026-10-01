import Foundation

public let QUEUE_KEY = "advenue.queue"
/// Persist debounce window. Bursts inside it coalesce into one write.
public let PERSIST_DEBOUNCE_MS = 100

/// Durable FIFO event buffer, mirroring sdk-core's `EventQueue` including its
/// persisted blob shape — the RN inversion has to read what TypeScript wrote.
///
/// Persist strategy: `enqueue` debounces so a burst costs one write; `ack` and
/// `clear` are flush boundaries and write synchronously, because stale storage
/// at those points means event loss on ack or double-send after a crash.
///
/// Confined to the engine's single consumer task. Not thread-safe, and
/// deliberately so: the actor owns it, and a lock here would hide a mistake
/// rather than prevent one.
public final class EventQueue {
  private var events: [ClientEvent]
  private var persistToken: CancelToken?
  private let store: KeyValueStore
  private let maxSize: Int
  private let scheduler: Scheduler

  public init(store: KeyValueStore, maxSize: Int = 10_000, scheduler: Scheduler) {
    self.store = store
    self.maxSize = maxSize
    self.scheduler = scheduler
    self.events = EventQueue.load(store)
  }

  /// A corrupt blob loads as empty rather than throwing: bricking the SDK on
  /// every launch is worse than losing an offline buffer.
  private static func load(_ store: KeyValueStore) -> [ClientEvent] {
    guard let raw = store.string(forKey: QUEUE_KEY), let data = raw.data(using: .utf8) else {
      return []
    }
    return (try? JSONDecoder().decode([ClientEvent].self, from: data)) ?? []
  }

  public var size: Int { events.count }

  public func enqueue(_ event: ClientEvent) {
    events.append(event)
    // Bound the buffer: a long offline period on a chatty app must not grow the
    // persisted blob without limit. Recent events are the ones worth keeping.
    if events.count > maxSize {
      events.removeFirst(events.count - maxSize)
    }
    schedulePersist()
  }

  /// Puts an event at the HEAD of the queue — the install, which is the first
  /// package of an installation and must not be preceded by the session and
  /// custom events recorded while enrichment ran. Over the cap, the oldest
  /// events behind it are dropped, never the event just placed.
  public func enqueueFirst(_ event: ClientEvent) {
    events.insert(event, at: 0)
    if events.count > maxSize {
      events.removeSubrange(1..<(1 + events.count - maxSize))
    }
    schedulePersist()
  }

  public func peek(_ max: Int) -> [ClientEvent] {
    Array(events.prefix(max))
  }

  public func ack(_ sent: [ClientEvent]) {
    guard !sent.isEmpty else { return }
    let ids = Set(sent.map(\.id))
    events.removeAll { ids.contains($0.id) }
    forcePersist()
  }

  public func clear() {
    events.removeAll()
    forcePersist()
  }

  private func schedulePersist() {
    guard persistToken == nil else { return }
    persistToken = scheduler.schedule(afterMs: PERSIST_DEBOUNCE_MS) { [weak self] in
      guard let self else { return }
      self.persistToken = nil
      self.write()
    }
  }

  private func forcePersist() {
    if let token = persistToken {
      scheduler.cancel(token)
      persistToken = nil
    }
    write()
  }

  private func write() {
    guard let data = try? EventEncoding.canonicalEncoder().encode(events) else { return }
    store.set(String(decoding: data, as: UTF8.self), forKey: QUEUE_KEY)
  }
}

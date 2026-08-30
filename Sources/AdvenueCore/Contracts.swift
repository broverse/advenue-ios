import Foundation

/// Synchronous key/value storage. On iOS this is a `UserDefaults` suite; in
/// tests it is an in-memory dictionary. Mirrors `StorageAdapter` in sdk-core.
public protocol KeyValueStore: Sendable {
  func string(forKey key: String) -> String?
  func set(_ value: String, forKey key: String)
  func removeObject(forKey key: String)
}

/// HMAC-SHA256, injected so `AdvenueCore` never imports a crypto library and
/// therefore builds anywhere. Production supplies CryptoKit; the Linux test
/// path supplies swift-crypto.
public protocol Signer: Sendable {
  /// Lowercase hex digest of `message` under `secret`, both UTF-8.
  func hmacSHA256Hex(secret: String, message: String) -> String
}

/// Milliseconds since the Unix epoch. Injected so vectors are deterministic.
public protocol Clock: Sendable {
  func nowMs() -> Int64
}

/// Opaque handle returned by `Scheduler.schedule`.
public typealias CancelToken = UInt64

/// Deferred execution, injected so the persist debounce is observable without
/// waiting for it.
public protocol Scheduler: Sendable {
  func schedule(afterMs: Int, _ work: @escaping @Sendable () -> Void) -> CancelToken
  func cancel(_ token: CancelToken)
}

/// Event, session and device id source. Injected for the same reason.
public protocol UUIDSource: Sendable {
  func next() -> String
}

/// HMAC over `"\(timestamp).\(body)"` — the Stripe-style construction in
/// `packages/signing`. Binding the timestamp is what makes replay detectable,
/// so the separator and the order are part of the contract, not a detail.
public func signRequest(
  _ signer: Signer,
  secret: String,
  timestamp: String,
  body: String
) -> String {
  signer.hmacSHA256Hex(secret: secret, message: "\(timestamp).\(body)")
}

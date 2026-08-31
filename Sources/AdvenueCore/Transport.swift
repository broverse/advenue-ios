import Foundation

/// What the core needs from a transport, and no more.
///
/// Declared here rather than in the platform layer so `AdvenueCore` keeps its
/// only-Foundation property while still owning the flush loop. The loop is
/// behaviour the `flush/` conformance vectors bind, so it cannot live above the
/// core: a rule the vectors cannot reach is a rule three implementations can
/// each interpret differently.
public protocol EventTransport: Sendable {
  /// Delivers one batch. Throws `IngestError` on a non-2xx response, and on a
  /// transport failure, which maps to 408.
  func send(_ events: [ClientEvent]) async throws
}

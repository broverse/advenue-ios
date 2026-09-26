import AdvenueCore
import Foundation
import os

/// Where `AdvenueConfig.debug` writes. The unified logging system in an app;
/// a recorder in tests.
protocol AdvenueLogSink: Sendable {
  func log(_ message: String)
}

/// `os.Logger`, public privacy: the lines carry failure contexts, counts and
/// the app id the server resolved — never an identifier or a payload — and a
/// debug aid that Console.app shows as `<private>` would not be one.
struct UnifiedLogSink: AdvenueLogSink {
  private let logger = Logger(subsystem: "io.advenue.sdk", category: "Advenue")
  func log(_ message: String) {
    logger.notice("\(message, privacy: .public)")
  }
}

/// Logs each accepted batch; failures already reach the log through the
/// wrapped `onError` (`flush.transport`, `flush.poison`).
struct LoggingTransport: EventTransport {
  let inner: any EventTransport
  let log: @Sendable (String) -> Void

  func send(_ events: [ClientEvent]) async throws {
    try await inner.send(events)
    log("[Advenue] sent \(events.count) event(s)")
  }
}

/// With `debug` on: the config with `onError` also writing to the log, and the
/// log itself. Off: the config unchanged and a log that discards.
func withDebugLogging(
  _ config: AdvenueConfig, sink: (any AdvenueLogSink)?
) -> (AdvenueConfig, @Sendable (String) -> Void) {
  guard config.debug else { return (config, { _ in }) }
  let sink = sink ?? UnifiedLogSink()
  var logged = config
  let report = config.onError
  logged.onError = { context, error in
    sink.log("[Advenue] \(context): \(error)")
    report(context, error)
  }
  return (logged, { sink.log($0) })
}

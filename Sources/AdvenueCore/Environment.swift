import Foundation

/// Where an SDK sends its events (spec 2 §7.1). Read-only after initialize,
/// as in Adjust. Production batches omit the field entirely.
public enum AdvenueEnvironment: String, Sendable {
  case production
  case sandbox
}

/// The environment the SDK last ran with, so a change between launches is seen.
public let ENVIRONMENT_KEY = "advenue.environment"

public let SANDBOX_WARNING =
  "Advenue: SANDBOX mode. Events go to the sandbox only: no attribution in reports, no postbacks. Set environment to production before release."

/// The server cannot be trusted with sandbox events: it does not advertise the
/// capability, or it answered a sandbox batch without saying `sandbox`. An
/// older server would file them as production, so the SDK stops uploading for
/// the rest of the process and keeps the events (spec 2 §7.2, P3).
public struct SandboxUnsupportedError: Error, Equatable, Sendable, CustomStringConvertible {
  public enum Reason: String, Sendable {
    case capabilityMissing
    case responseMismatch
  }
  public let reason: Reason
  public init(_ reason: Reason) { self.reason = reason }
  public var description: String {
    "Advenue: this server does not support sandbox; events are kept on the device and not sent."
  }
}

/// Spec 2 §7.2: on an environment change since the last launch, drops the
/// queued events (they belong to the other environment) and the install flag
/// (so the new environment records its own install). Device and installation
/// ids are kept. Returns the number of events dropped, or nil when unchanged.
/// An absent record means production: releases before 1.4.0 had no option.
@discardableResult
public func reconcileEnvironment(
  _ current: AdvenueEnvironment, store: KeyValueStore, scheduler: Scheduler
) -> Int? {
  let previous =
    AdvenueEnvironment(rawValue: store.string(forKey: ENVIRONMENT_KEY) ?? "") ?? .production
  store.set(current.rawValue, forKey: ENVIRONMENT_KEY)
  guard previous != current else { return nil }
  let queue = EventQueue(store: store, scheduler: scheduler)
  let dropped = queue.size
  queue.clear()
  store.removeObject(forKey: INSTALL_SENT_KEY)
  return dropped
}

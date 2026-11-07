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
  guard previous != current else {
    // Pins the record for installs that had none, once the environment is known.
    if store.string(forKey: ENVIRONMENT_KEY) == nil {
      store.set(current.rawValue, forKey: ENVIRONMENT_KEY)
    }
    return nil
  }
  let queue = EventQueue(store: store, scheduler: scheduler)
  let dropped = queue.size
  queue.clear()
  store.removeObject(forKey: INSTALL_SENT_KEY)
  // U2: an install a withdrawal kept belongs to the old environment too.
  store.removeObject(forKey: INSTALL_DEFERRED_KEY)
  // LAST: a crash before this line leaves the old record, so the next launch
  // sees the change again and clears again. Writing it first would let the
  // old sandbox queue be uploaded as production.
  store.set(current.rawValue, forKey: ENVIRONMENT_KEY)
  return dropped
}

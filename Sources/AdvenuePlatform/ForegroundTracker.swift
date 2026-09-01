/// What UIKit told us about the app.
public enum LifecycleSignal: Sendable {
  case didBecomeActive
  /// Transient. Control Center, an incoming call, the app switcher preview —
  /// none of which is a backgrounding, and all of which are followed by
  /// `didBecomeActive` again.
  case willResignActive
  case didEnterBackground
}

public enum ForegroundTransition: Sendable, Equatable {
  case none
  case enteredForeground
  case enteredBackground
}

/// The foreground/background decision, as a pure state machine — no UIKit type
/// appears in this file, which is what makes it provable without a device.
///
/// It is deliberately simpler than the Android tracker, and the difference is
/// the platform rather than an omission. Android has to survive a rotation
/// recreating the activity, which walks a started-activity counter 1 → 0 → 1
/// and needs both a configuration-change check and a 700 ms debounce to avoid
/// emitting a phantom `session_end`. iOS recreates nothing, and
/// `didEnterBackground` is unambiguous, so pairing it against `didBecomeActive`
/// is the whole rule.
///
/// What DOES bite on iOS is the transient interruption, and that is what
/// `willResignActive` is here to be ignored for. Reading it as a backgrounding
/// ends a session every time a notification banner appears.
public struct ForegroundTracker: Sendable {
  private var inForeground: Bool

  /// - Parameter inForeground: seed for an SDK that already opened its own
  ///   session at `initialize`, so the activation that follows does not open a
  ///   second one.
  public init(inForeground: Bool = false) {
    self.inForeground = inForeground
  }

  public mutating func on(_ signal: LifecycleSignal) -> ForegroundTransition {
    switch signal {
    case .willResignActive:
      return .none
    case .didBecomeActive:
      if inForeground { return .none }
      inForeground = true
      return .enteredForeground
    case .didEnterBackground:
      if !inForeground { return .none }
      inForeground = false
      return .enteredBackground
    }
  }
}

import Foundation

public let DAY_MS: Int64 = 86_400_000

/// SKAdNetwork 4 measures three windows from first launch. Boundaries are
/// Apple's and inclusive at the top: `[0,2d] → 1`, `(2d,7d] → 2`,
/// `(7d,35d] → 3`, beyond that nothing is measurable.
///
/// A device whose clock is behind first launch produces a negative age and
/// reads as window 1. Degrade, never throw: this runs on a path the SDK
/// swallows, so an exception here would silently stop measurement instead of
/// reporting anything.
public func deriveWindowIndex(firstLaunchAt: Int64, nowMs: Int64) -> Int? {
  let age = nowMs - firstLaunchAt
  if age <= 2 * DAY_MS { return 1 }
  if age <= 7 * DAY_MS { return 2 }
  if age <= 35 * DAY_MS { return 3 }
  return nil
}

public func skanStateKey(installationId: String) -> String {
  "advenue.skan.state.\(installationId)"
}

/// One measurement window's accumulation.
public struct WindowState: Codable, Equatable, Sendable {
  public var seenEvents: [String] = []
  /// Canonical micros. A string, because money must not go through a Double.
  public var revenueMicros: String = "0"
  public var lastFine: Int?
  public var lastCoarse: CoarseValue?
  public var locked: Bool = false
  /// Write-ahead intent: what we are about to tell Apple. Persisted BEFORE the
  /// call so a crash between the two cannot leave the device believing it
  /// reported a value it never sent.
  public var pendingFine: Int?
  public var pendingCoarse: CoarseValue?

  public init() {}
}

/// Coarse buckets are ordered, and the gate below compares them as an order
/// rather than for equality — a move from low to medium is progress, the
/// reverse is not.
func coarseOrder(_ value: CoarseValue) -> Int {
  switch value {
  case .low: return 0
  case .medium: return 1
  case .high: return 2
  }
}

/// The persisted blob. **Field names are frozen**: the RN inversion has to read
/// what TypeScript wrote, and a rename silently restarts every device's SKAN
/// measurement — which looks like a fleet-wide drop in postback quality with no
/// error anywhere.
public struct SkanMeasurementState: Codable, Equatable, Sendable {
  public var v: Int = 2
  public var firstLaunchAt: Int64
  public var configVersion: Int = 0
  public var windows: [String: WindowState]

  public init(firstLaunchAt: Int64) {
    self.firstLaunchAt = firstLaunchAt
    self.windows = ["w1": WindowState(), "w2": WindowState(), "w3": WindowState()]
  }
}

/// What the platform layer should tell Apple, or nil when there is nothing
/// worth saying.
public struct SkanUpdate: Equatable, Sendable {
  public let fineValue: Int
  public let coarseValue: CoarseValue
  public let windowIndex: Int
  /// True on the last update of a window: Apple stops accepting changes and
  /// sends the postback sooner.
  public let lockWindow: Bool
}

/// The client half of SKAN 4: accumulate into the current window, recompute,
/// and decide whether an update is worth making.
///
/// Confined to the engine's thread like every other piece of state.
public final class SkanStateMachine {
  private let store: KeyValueStore
  private let clock: Clock
  private let installationId: String
  private let mapper: ConversionValueMapper
  private let currency: String?
  private var state: SkanMeasurementState

  public init(
    store: KeyValueStore,
    clock: Clock,
    installationId: String,
    mapper: ConversionValueMapper,
    currency: String? = nil,
    configVersion: Int = 0
  ) {
    self.store = store
    self.clock = clock
    self.installationId = installationId
    self.mapper = mapper
    self.currency = currency
    self.state = Self.load(store, key: skanStateKey(installationId: installationId))
      ?? SkanMeasurementState(firstLaunchAt: clock.nowMs())
    // Recorded so the server can tell which config produced a reported value.
    // A schema change mid-window otherwise looks like a device behaving oddly.
    self.state.configVersion = configVersion
    persist()
  }

  /// Records an event and returns the update to make, or nil.
  ///
  /// Nil for three distinct reasons, all of which matter: the install is past
  /// the last window, the window is locked, or the computed value has not
  /// changed. That last one is not an optimisation — SKAN updates are
  /// rate-limited by the system and each one restarts a timer, so a no-op
  /// update costs the advertiser measurement resolution.
  @discardableResult
  public func record(
    event: String?, revenueMicros: String? = nil, revenueCurrency: String? = nil
  ) -> SkanUpdate? {
    guard let index = deriveWindowIndex(firstLaunchAt: state.firstLaunchAt, nowMs: clock.nowMs())
    else { return nil }
    let key = "w\(index)"
    var window = state.windows[key] ?? WindowState()
    if window.locked { return nil }

    if let event, !window.seenEvents.contains(event) { window.seenEvents.append(event) }
    if let revenueMicros, isCanonicalMicros(revenueMicros) {
      // Revenue accumulates within a window and does not carry into the next:
      // each SKAN window measures its own period.
      if window.revenueMicros == "0" || revenueCurrency == currency {
        window.revenueMicros = addMicros(window.revenueMicros, revenueMicros)
      }
    }

    let computed = mapper.compute(
      MeasurementState(
        events: window.seenEvents,
        revenueMicros: window.revenueMicros,
        revenueCurrency: revenueCurrency ?? currency))

    // Monotonic within the window, and the two baselines differ on purpose.
    //
    // Fine baseline is **0**, not -1: a computed fine of 0 is the mapper's "no
    // rule matched" default, so on its own it is not news and must not spend a
    // rate-limited update. Fine is also only meaningful in window 1 — after
    // that Apple ignores it for v4 ads.
    //
    // Coarse baseline is **-1**, so the first coarse activation fires even at
    // `low`. That is what keeps windows 2 and 3 reporting at all; gating them
    // on fine alone silently no-ops them.
    let fineIncreased = index == 1 && computed.fineValue > (window.lastFine ?? 0)
    let coarseIncreased =
      coarseOrder(computed.coarseValue) > (window.lastCoarse.map(coarseOrder) ?? -1)

    guard fineIncreased || coarseIncreased else {
      state.windows[key] = window
      persist()
      return nil
    }

    // After window 1, send window 1's FROZEN fine: Apple ignores it on v4 ads,
    // and a valid value still serves v3-signed ones.
    let fineToSend =
      index == 1 ? computed.fineValue : (state.windows["w1"]?.lastFine ?? 0)

    window.pendingFine = index == 1 ? computed.fineValue : nil
    window.pendingCoarse = computed.coarseValue
    state.windows[key] = window
    persist()

    return SkanUpdate(
      fineValue: fineToSend, coarseValue: computed.coarseValue,
      windowIndex: index, lockWindow: false)
  }

  /// Commits an update the platform layer actually delivered.
  ///
  /// Separate from `record` because the Apple call can fail, and a device that
  /// recorded a value it never sent would refuse to send it again — the window
  /// would report nothing for the rest of its life.
  public func confirm(_ update: SkanUpdate) {
    let key = "w\(update.windowIndex)"
    guard var window = state.windows[key] else { return }
    if update.windowIndex == 1, let pending = window.pendingFine { window.lastFine = pending }
    if let pending = window.pendingCoarse { window.lastCoarse = pending }
    if update.lockWindow { window.locked = true }
    window.pendingFine = nil
    window.pendingCoarse = nil
    state.windows[key] = window
    persist()
  }

  /// Discards an intent the platform layer could not deliver, so the next
  /// qualifying event tries again.
  public func abandon(_ update: SkanUpdate) {
    let key = "w\(update.windowIndex)"
    guard var window = state.windows[key] else { return }
    window.pendingFine = nil
    window.pendingCoarse = nil
    state.windows[key] = window
    persist()
  }

  /// Closes a window to further updates. Apple then stops accepting changes, so
  /// sending after this is an update the system silently discards while the SDK
  /// believes it landed.
  public func lock(window index: Int) {
    let key = "w\(index)"
    guard var window = state.windows[key] else { return }
    window.locked = true
    state.windows[key] = window
    persist()
  }

  public func snapshot() -> SkanMeasurementState { state }

  private func persist() {
    guard let data = try? EventEncoding.canonicalEncoder().encode(state) else { return }
    store.set(
      String(decoding: data, as: UTF8.self),
      forKey: skanStateKey(installationId: installationId))
  }

  /// A corrupt blob loads as fresh state rather than throwing — the same rule
  /// the event queue follows, and for the same reason: bricking measurement on
  /// every launch is worse than losing one device's accumulation.
  private static func load(_ store: KeyValueStore, key: String) -> SkanMeasurementState? {
    guard let raw = store.string(forKey: key), let data = raw.data(using: .utf8) else {
      return nil
    }
    return try? JSONDecoder().decode(SkanMeasurementState.self, from: data)
  }
}

/// Adds two canonical non-negative base-10 micro amounts without a bignum and
/// without a Double, which would lose exactness above 2^53 micros.
func addMicros(_ lhs: String, _ rhs: String) -> String {
  var carry = 0
  var out: [Character] = []
  let a = Array(lhs.reversed()), b = Array(rhs.reversed())
  for i in 0..<max(a.count, b.count) {
    let x = i < a.count ? Int(String(a[i])) ?? 0 : 0
    let y = i < b.count ? Int(String(b[i])) ?? 0 : 0
    let sum = x + y + carry
    out.append(Character(String(sum % 10)))
    carry = sum / 10
  }
  if carry > 0 { out.append(Character(String(carry))) }
  let result = String(out.reversed())
  // Strip leading zeros to keep the value canonical, which the comparison and
  // the server's schema both require.
  let trimmed = result.drop(while: { $0 == "0" })
  return trimmed.isEmpty ? "0" : String(trimmed)
}

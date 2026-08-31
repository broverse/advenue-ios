import Foundation
import XCTest

@testable import AdvenueCore

final class SkanStateTests: XCTestCase {
  private func mapper() throws -> ConversionValueMapper {
    try ConversionValueMapper(
      ConversionValueConfig(
        rules: [
          ConversionValueRule(fineValue: 10, events: ["signup"]),
          ConversionValueRule(fineValue: 30, minRevenueMicros: "1000000"),
          ConversionValueRule(fineValue: 50, minRevenueMicros: "5000000"),
        ],
        revenueCurrency: "USD"))
  }

  private func machine(
    _ store: MemoryStore, _ clock: MutableClock
  ) throws -> SkanStateMachine {
    SkanStateMachine(
      store: store, clock: clock, installationId: "inst-1",
      mapper: try mapper(), currency: "USD")
  }

  /// Apple's window boundaries, inclusive at the top. Each one moves a postback
  /// into a different measurement period, so an off-by-one here mis-files the
  /// conversion rather than losing it — harder to notice and worse.
  func testWindowBoundaries() {
    XCTAssertEqual(deriveWindowIndex(firstLaunchAt: 0, nowMs: 0), 1)
    XCTAssertEqual(deriveWindowIndex(firstLaunchAt: 0, nowMs: 2 * DAY_MS), 1)
    XCTAssertEqual(deriveWindowIndex(firstLaunchAt: 0, nowMs: 2 * DAY_MS + 1), 2)
    XCTAssertEqual(deriveWindowIndex(firstLaunchAt: 0, nowMs: 7 * DAY_MS), 2)
    XCTAssertEqual(deriveWindowIndex(firstLaunchAt: 0, nowMs: 7 * DAY_MS + 1), 3)
    XCTAssertEqual(deriveWindowIndex(firstLaunchAt: 0, nowMs: 35 * DAY_MS), 3)
    XCTAssertNil(deriveWindowIndex(firstLaunchAt: 0, nowMs: 35 * DAY_MS + 1))
  }

  /// A device whose clock is set behind first launch produces a negative age.
  /// It reads as window 1: this runs on a path the SDK swallows, so throwing
  /// would silently stop measurement instead of reporting anything.
  func testAFutureClockReadsAsWindowOne() {
    XCTAssertEqual(deriveWindowIndex(firstLaunchAt: 1_000_000, nowMs: 0), 1)
  }

  func testTheFirstQualifyingEventProducesAnUpdate() throws {
    let skan = try machine(MemoryStore(), MutableClock())

    let update = skan.record(event: "signup")
    XCTAssertEqual(update?.fineValue, 10)
    XCTAssertEqual(update?.coarseValue, .low)
    XCTAssertEqual(update?.windowIndex, 1)
  }

  /// A computed fine of 0 is the mapper's "no rule matched" default, so on its
  /// own it is not news and must not spend a rate-limited update. But the FIRST
  /// coarse activation still fires, because windows 2 and 3 report through the
  /// coarse comparator and gating them on fine alone silently no-ops them.
  func testTheFineBaselineIsZeroAndTheCoarseBaselineIsNot() throws {
    let skan = try machine(MemoryStore(), MutableClock())

    let first = skan.record(event: "unmatched")
    XCTAssertEqual(first?.fineValue, 0, "fine 0 alone is not news")
    XCTAssertEqual(first?.coarseValue, .low, "but the first coarse activation is")
    skan.confirm(first!)

    XCTAssertNil(
      skan.record(event: "another-unmatched"),
      "a second fine-0/low computation has nothing new to say")
  }

  /// Monotonic within the window: a value that goes backwards is not progress
  /// and must not be reported.
  func testAValueThatGoesBackwardsIsNotReported() throws {
    let skan = try machine(MemoryStore(), MutableClock())
    let up = skan.record(event: nil, revenueMicros: "5000000", revenueCurrency: "USD")
    XCTAssertEqual(up?.fineValue, 50)
    skan.confirm(up!)
    XCTAssertNil(skan.record(event: "signup"), "fine 10 is lower than the reported 50")
  }

  /// Apple ignores the fine value after window 1 for v4 ads, so the frozen
  /// window-1 value is what travels — a valid value still serves v3-signed ads.
  func testAfterWindowOneTheFrozenFineIsSent() throws {
    let clock = MutableClock()
    let skan = try machine(MemoryStore(), clock)
    let first = skan.record(event: nil, revenueMicros: "1000000", revenueCurrency: "USD")
    XCTAssertEqual(first?.fineValue, 30)
    skan.confirm(first!)

    clock.ms = 3 * DAY_MS
    let later = skan.record(event: nil, revenueMicros: "5000000", revenueCurrency: "USD")
    XCTAssertEqual(later?.windowIndex, 2)
    XCTAssertEqual(later?.fineValue, 30, "window 1's frozen fine, not window 2's computation")
    XCTAssertEqual(later?.coarseValue, .high, "the coarse value is window 2's own")
  }

  /// The Apple call can fail. A device that recorded a value it never sent
  /// would refuse to send it again, and the window would report nothing for the
  /// rest of its life.
  func testAnUnconfirmedUpdateIsRetried() throws {
    let skan = try machine(MemoryStore(), MutableClock())
    let update = skan.record(event: "signup")
    XCTAssertNotNil(update)
    skan.abandon(update!)

    let retry = skan.record(event: "signup")
    XCTAssertEqual(retry?.fineValue, 10, "the value was never delivered, so it is still news")
  }

  /// Not an optimisation. SKAN updates are rate-limited by the system and each
  /// one restarts a timer, so a no-op update costs the advertiser measurement
  /// resolution.
  func testNoUpdateWhenTheComputedValueIsUnchanged() throws {
    let skan = try machine(MemoryStore(), MutableClock())
    let first = skan.record(event: "signup")
    XCTAssertNotNil(first)
    skan.confirm(first!)
    XCTAssertNil(skan.record(event: "signup"), "the same event must not update twice")
    XCTAssertNil(skan.record(event: "unrelated"), "an event no rule mentions changes nothing")
  }

  /// A locked window accepts nothing further — that is what locking means, and
  /// forgetting it sends an update Apple silently discards while the SDK
  /// believes it landed.
  func testALockedWindowRefusesUpdates() throws {
    let skan = try machine(MemoryStore(), MutableClock())
    skan.lock(window: 1)
    XCTAssertNil(skan.record(event: "signup"))
  }

  /// Revenue accumulates within a window and does not carry into the next: each
  /// SKAN window measures its own period.
  func testRevenueAccumulatesWithinAWindowAndResetsBetween() throws {
    let clock = MutableClock()
    let store = MemoryStore()
    let skan = try machine(store, clock)

    // Below the threshold: fine stays 0, but the first coarse activation fires.
    let below = skan.record(event: nil, revenueMicros: "600000", revenueCurrency: "USD")
    XCTAssertEqual(below?.fineValue, 0)
    skan.confirm(below!)

    let crossed = skan.record(event: nil, revenueMicros: "400000", revenueCurrency: "USD")
    XCTAssertEqual(crossed?.fineValue, 30, "600000 + 400000 crosses the 1000000 threshold")
    skan.confirm(crossed!)

    // Move into window 2: its accumulation starts from nothing.
    clock.ms = 3 * DAY_MS
    let inWindowTwo = skan.record(event: nil, revenueMicros: "100000", revenueCurrency: "USD")
    XCTAssertNotNil(inWindowTwo, "window 2's first coarse activation still reports")
    XCTAssertEqual(inWindowTwo?.coarseValue, .low)
    XCTAssertEqual(skan.snapshot().windows["w2"]?.revenueMicros, "100000")
    XCTAssertEqual(
      skan.snapshot().windows["w1"]?.revenueMicros, "1000000",
      "window 1's accumulation must not be disturbed")
  }

  /// Exactness above 2^53 micros, where a Double would round and silently
  /// misprice the conversion.
  func testMicroAdditionIsExact() {
    XCTAssertEqual(addMicros("9007199254740992", "1"), "9007199254740993")
    XCTAssertEqual(addMicros("999", "1"), "1000")
    XCTAssertEqual(addMicros("0", "0"), "0")
    XCTAssertEqual(addMicros("0", "250000"), "250000")
  }

  /// The persisted shape is frozen: the RN inversion has to read what
  /// TypeScript wrote, and a rename silently restarts every device's SKAN
  /// measurement — a fleet-wide drop in postback quality with no error anywhere.
  func testStateRoundTripsThroughThePersistedBlob() throws {
    let store = MemoryStore()
    let clock = MutableClock()
    let first = try machine(store, clock)
    let update = first.record(event: "signup", revenueMicros: "250000", revenueCurrency: "USD")
    first.confirm(update!)

    let blob = store.raw(skanStateKey(installationId: "inst-1"))
    XCTAssertNotNil(blob)
    XCTAssertTrue(blob!.contains("\"firstLaunchAt\""), blob!)
    XCTAssertTrue(blob!.contains("\"w1\""), blob!)

    let reborn = try machine(store, clock)
    XCTAssertEqual(reborn.snapshot().windows["w1"]?.revenueMicros, "250000")
    XCTAssertEqual(reborn.snapshot().windows["w1"]?.lastFine, 10)
    XCTAssertNil(
      reborn.record(event: "signup"),
      "a reloaded machine must remember what it already reported")
  }

  /// A corrupt blob loads as fresh state rather than throwing — the same rule
  /// the event queue follows. Bricking measurement on every launch is worse
  /// than losing one device's accumulation.
  func testACorruptBlobLoadsAsFreshState() throws {
    let store = MemoryStore()
    store.preload(skanStateKey(installationId: "inst-1"), "{not json")
    let skan = try machine(store, MutableClock())
    XCTAssertEqual(skan.snapshot().windows["w1"]?.revenueMicros, "0")
    XCTAssertNotNil(skan.record(event: "signup"))
  }

  func testPastTheLastWindowNothingIsReported() throws {
    let clock = MutableClock()
    let skan = try machine(MemoryStore(), clock)
    clock.ms = 36 * DAY_MS
    XCTAssertNil(skan.record(event: "signup"))
  }
}

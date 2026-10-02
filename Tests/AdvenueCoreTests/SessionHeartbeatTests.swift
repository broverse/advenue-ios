import Foundation
import XCTest

@testable import AdvenueCore

/// F-SDK-7: a process that dies without backgrounding does not split the
/// session when it is relaunched inside the window of its last activity.
final class SessionHeartbeatTests: XCTestCase {
  private func engine(_ store: MemoryStore, _ clock: MutableClock) -> AdvenueEngine {
    AdvenueEngine(
      config: EngineConfig(apiKey: "apk_test", platform: "ios", deviceId: "d1"),
      store: store, clock: clock,
      scheduler: RecordingScheduler(), uuid: SequentialUUIDs(prefix: "ev"))
  }

  func testATrackedEventIsTheKillTimeForTheNextLaunch() async {
    let store = MemoryStore()
    let clock = MutableClock()
    clock.ms = 1_000_000

    let first = engine(store, clock)
    await first.notifyForeground()
    clock.ms += 20_000
    await first.track("example_purchase")
    // The process dies here: no background, no session_end.

    clock.ms += 40_000
    let relaunched = engine(store, clock)
    await relaunched.notifyForeground()

    let sessionEvents = await relaunched.pendingEvents().filter { $0.type == "session" }
    let names = sessionEvents.map(\.name)
    // Launch 1's queue was never persisted (the test scheduler holds the
    // debounce), so only what the relaunch emitted is here.
    XCTAssertEqual(
      names, ["session_end"],
      "the relaunch must close the orphan and must not start a second session")
    let end = sessionEvents.last
    XCTAssertEqual(end?.properties?["synthetic"], .bool(true))
    XCTAssertEqual(end?.properties?["activeMs"], .int(20_000))
  }

  /// X-SDK-1: the relaunch tracks and flushes BEFORE its foreground transition
  /// (`didFinishLaunching` runs before `didBecomeActive`). That activity belongs
  /// to the new process, not to the killed sub-session: the dead 40 s must not
  /// be counted as active time.
  func testEventsBeforeTheRelaunchForegroundDoNotMoveTheKillTime() async {
    let store = MemoryStore()
    let clock = MutableClock()
    clock.ms = 1_000_000

    let first = engine(store, clock)
    await first.notifyForeground()
    clock.ms += 20_000
    await first.track("example_purchase")
    // The process dies here: no background, no session_end.

    clock.ms += 40_000
    let relaunched = engine(store, clock)
    await relaunched.track("example_purchase")
    clock.ms += 300
    await relaunched.flush()
    await relaunched.notifyForeground()

    let end = await relaunched.pendingEvents().first { $0.name == "session_end" }
    XCTAssertEqual(end?.properties?["synthetic"], .bool(true))
    XCTAssertEqual(end?.properties?["activeMs"], .int(20_000))
  }

  func testAFlushTickIsTheKillTimeToo() async {
    let store = MemoryStore()
    let clock = MutableClock()
    clock.ms = 1_000_000

    let first = engine(store, clock)
    await first.notifyForeground()
    clock.ms += 15_000
    await first.flush()

    clock.ms += 1_800_000  // a full window after the tick
    let relaunched = engine(store, clock)
    await relaunched.notifyForeground()

    let names = await relaunched.pendingEvents().filter { $0.type == "session" }.map(\.name)
    XCTAssertEqual(names, ["session_end", "session_start"])
    let end = await relaunched.pendingEvents().filter { $0.name == "session_end" }.first
    XCTAssertEqual(end?.properties?["activeMs"], .int(15_000))
  }

  /// State persisted before `lastActiveAt` existed still loads: an app updating
  /// its SDK must not restart session numbering.
  func testStateWithoutLastActiveAtStillLoads() async {
    let store = MemoryStore()
    store.preload(
      SESSION_STATE_KEY,
      #"{"activeStart":1000,"firstForegroundAt":1000,"lastBackgroundAt":null,"sessionId":"s-old","#
        + #""sessionNumber":7,"subSessionCount":1,"timeSpentMs":0}"#)
    let clock = MutableClock()
    clock.ms = 5_000

    let e = engine(store, clock)
    await e.notifyForeground()

    let events = await e.pendingEvents()
    XCTAssertEqual(events.map(\.name), ["session_end"])
    XCTAssertEqual(events.first?.properties?["sessionNumber"], .int(7))
  }
}

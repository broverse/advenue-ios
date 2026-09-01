import XCTest

@testable import AdvenuePlatform

/// The foreground decision, tested as a pure machine.
///
/// Same reason the Android tracker is extracted: driving real `UIApplication`
/// notifications would test the simulator's ordering rather than the rule, and
/// the rule is where the mistakes are. What stays a device claim is that the
/// real notification order matches the signals fed in here.
final class ForegroundTrackerTests: XCTestCase {
  func testTheFirstActivationEntersTheForeground() {
    var tracker = ForegroundTracker()
    XCTAssertEqual(tracker.on(.didBecomeActive), .enteredForeground)
  }

  /// The mistake this machine exists to prevent.
  ///
  /// Pulling down Control Center, taking a call, or opening the app switcher
  /// fires `willResignActive` and then `didBecomeActive` again — with no
  /// backgrounding in between. Treating resign-active as background would end a
  /// session every time a notification banner appeared, then start a new one a
  /// second later: session counts inflated by an order of magnitude and
  /// durations shredded.
  func testAnInterruptionIsNotABackgrounding() {
    var tracker = ForegroundTracker()
    _ = tracker.on(.didBecomeActive)

    XCTAssertEqual(tracker.on(.willResignActive), .none)
    XCTAssertEqual(tracker.on(.didBecomeActive), .none, "the app never left the foreground")
  }

  func testABackgroundingEndsTheForegroundAndAReturnStartsANewOne() {
    var tracker = ForegroundTracker()
    _ = tracker.on(.didBecomeActive)

    // The real order: resign active, then enter background.
    XCTAssertEqual(tracker.on(.willResignActive), .none)
    XCTAssertEqual(tracker.on(.didEnterBackground), .enteredBackground)
    XCTAssertEqual(tracker.on(.didBecomeActive), .enteredForeground)
  }

  /// Duplicates are ordinary. A scene-based app can deliver `didBecomeActive`
  /// more than once for one activation, and an SDK initialised late has already
  /// missed the first one.
  func testRepeatedSignalsAreIdempotent() {
    var tracker = ForegroundTracker()
    XCTAssertEqual(tracker.on(.didBecomeActive), .enteredForeground)
    XCTAssertEqual(tracker.on(.didBecomeActive), .none)

    XCTAssertEqual(tracker.on(.didEnterBackground), .enteredBackground)
    XCTAssertEqual(tracker.on(.didEnterBackground), .none)
  }

  /// `initialize` opens the session itself, so the activation that follows it
  /// must not open a second one. Seeding the machine is what makes the SDK's
  /// own first foreground and the platform's agree.
  func testASeededTrackerIgnoresTheActivationThatFollowsInitialize() {
    var tracker = ForegroundTracker(inForeground: true)
    XCTAssertEqual(tracker.on(.didBecomeActive), .none)
    XCTAssertEqual(tracker.on(.didEnterBackground), .enteredBackground)
  }
}

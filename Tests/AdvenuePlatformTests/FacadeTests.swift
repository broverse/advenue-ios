import Foundation
import XCTest

@testable import Advenue
@testable import AdvenueCore
@testable import AdvenuePlatform

final class FacadeTests: XCTestCase {
  override func tearDown() {
    Advenue.shutdown()
    super.tearDown()
  }

  /// The simulator's XCTest bundle has no keychain entitlement, so identity
  /// resolves as `.deferred` and `initialize` deliberately starts nothing.
  /// That is the SDK behaving correctly, and it is also why the facade tests
  /// assert on state rather than on delivered events.
  func testDeferredIdentityStartsNothingAndReportsWhy() {
    let contexts = Locked<[String]>([])
    Advenue.initialize(
      AdvenueConfig(apiKey: "apk_live_x", onError: { context, _ in contexts.mutate { $0.append(context) } }))

    XCTAssertTrue(
      contexts.value.contains("identity.deferred"),
      "a keychain that cannot be read must be reported, not silently worked around")
  }

  func testDeviceIdIsNilWhileIdentityIsDeferred() async {
    Advenue.initialize(AdvenueConfig(apiKey: "apk_live_x"))
    let id = await Advenue.deviceId()
    // Not a guess, not a fresh UUID — nil. Returning an invented id here is
    // the phantom-device bug the whole identity design exists to prevent.
    XCTAssertNil(id)
  }

  func testInitializeTwiceIsSafe() {
    // Replace-and-shut-down. If the first pipe survived, two consumer tasks
    // would drain one stream and events would be handled twice or lost.
    let config = AdvenueConfig(apiKey: "apk_live_x")
    Advenue.initialize(config)
    Advenue.initialize(config)
    Advenue.track("purchase")
    // Reaching here without a crash or a hang is the contract; the ordering
    // guarantees themselves are covered by AdvenueCore's ConcurrencyTests.
  }

  func testDeepLinkBeforeInitializeIsBufferedNotDropped() {
    let state = FacadeState()
    state.deepLink(URL(string: "https://go.advenue.io/abc")!)
    state.deepLink(URL(string: "https://go.advenue.io/def")!)
    XCTAssertEqual(
      state.bufferedDeepLinkCount, 2,
      "a cold start from a link runs the app delegate before initialize, and those are exactly the links that carry attribution")
  }

  func testTrackBeforeInitializeDoesNotCrash() {
    Advenue.shutdown()
    Advenue.track("too_early")
    Advenue.setUserId("u_1")
    Advenue.setConsent(true)
    // A no-op, not a crash: an SDK that traps when called out of order takes
    // the host app down with it.
  }

  func testVersionIsStampedAndParsable() {
    XCTAssertFalse(AdvenueVersion.current.isEmpty)
    XCTAssertEqual(AdvenueVersion.current.split(separator: ".").count, 3)
  }
}

/// Minimal lock box so a test closure can accumulate across concurrency
/// domains under Swift 6 checking.
final class Locked<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: T
  init(_ value: T) { storage = value }
  var value: T {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
  func mutate(_ body: (inout T) -> Void) {
    lock.lock()
    body(&storage)
    lock.unlock()
  }
}

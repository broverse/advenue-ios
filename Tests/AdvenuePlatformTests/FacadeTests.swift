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

  /// Keychain availability differs by environment: a signed macOS test process
  /// can read it, while an unsigned simulator XCTest bundle has no entitlement
  /// and every query answers errSecMissingEntitlement. Both are real
  /// situations, so the assertion is the invariant that must hold in either —
  /// asserting one environment would make this a test of the runner.
  func testDeferralAndDeviceIdAlwaysAgree() async {
    let contexts = Locked<[String]>([])
    Advenue.initialize(
      AdvenueConfig(
        apiKey: "apk_live_x",
        onError: { context, _ in contexts.mutate { $0.append(context) } }))

    let deferred = contexts.value.contains("identity.deferred")
    let id = await Advenue.deviceId()

    if deferred {
      // Nothing started, so nothing may claim an identity. Returning an
      // invented id here is the phantom-device bug the design exists to
      // prevent.
      XCTAssertNil(id, "a deferred identity must not produce a device id")
    } else {
      XCTAssertNotNil(id, "a resolved identity must produce one")
      XCTAssertFalse(id!.isEmpty)
    }
  }

  /// The device id comes from the Keychain, not a fresh mint per launch. When
  /// it is readable at all, restarting must return the same value — otherwise
  /// every launch looks like a new device and every install is counted twice.
  func testDeviceIdIsStableAcrossRestarts() async {
    Advenue.initialize(AdvenueConfig(apiKey: "apk_live_x"))
    let first = await Advenue.deviceId()
    Advenue.shutdown()
    Advenue.initialize(AdvenueConfig(apiKey: "apk_live_x"))
    let second = await Advenue.deviceId()
    XCTAssertEqual(first, second)
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

  /// B3: query'deki token/e-posta ham gönderilmez.
  func testDeepLinkQueryIsStripped() {
    let state = FacadeState()
    XCTAssertEqual(
      state.stripUrlQuery(URL(string: "advenue://open?token=secret&email=a@b.com")!),
      "advenue://open")
    XCTAssertEqual(
      state.stripUrlQuery(URL(string: "https://go.advenue.io/abc")!),
      "https://go.advenue.io/abc")
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

  /// B5: `http://` kuralı.
  func testInsecureEndpointRule() {
    XCTAssertTrue(AdvenueConfig.isSecureEndpoint("https://ingest.advenue.io"))
    XCTAssertTrue(AdvenueConfig.isSecureEndpoint("HTTPS://x.test/y"))
    XCTAssertFalse(AdvenueConfig.isSecureEndpoint("http://localhost:8080"))
    XCTAssertFalse(AdvenueConfig.isSecureEndpoint("ftp://x"))
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

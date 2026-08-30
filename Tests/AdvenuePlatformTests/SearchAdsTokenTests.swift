import Foundation
import XCTest

@testable import AdvenuePlatform

/// Counts calls across concurrency domains without tripping Swift 6's data
/// race checks.
private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func increment() -> Int {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return value
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

final class SearchAdsTokenTests: XCTestCase {
  func testReturnsTheTokenOnFirstSuccess() async {
    let calls = Counter()
    let fetcher = SearchAdsTokenFetcher(attempts: 3, delayMs: 0) {
      _ = calls.increment()
      return "token-1"
    }
    let token = await fetcher.token()
    XCTAssertEqual(token, "token-1")
    XCTAssertEqual(calls.count, 1)
  }

  /// The defect this exists to fix. AAAttribution's token fails transiently
  /// right after install for roughly 8% of users, and the RN module gives up
  /// on the first throw — those installs silently become organic and Apple
  /// Search Ads spend goes unattributed.
  func testRetriesATransientFailure() async {
    let calls = Counter()
    let fetcher = SearchAdsTokenFetcher(attempts: 3, delayMs: 0) {
      if calls.increment() < 3 { throw SearchAdsError.transient }
      return "token-late"
    }
    let token = await fetcher.token()
    XCTAssertEqual(token, "token-late")
    XCTAssertEqual(calls.count, 3)
  }

  func testDoesNotRetryAnUnsupportedPlatform() async {
    let calls = Counter()
    let fetcher = SearchAdsTokenFetcher(attempts: 3, delayMs: 0) {
      _ = calls.increment()
      throw SearchAdsError.unsupported
    }
    let token = await fetcher.token()
    XCTAssertNil(token)
    XCTAssertEqual(
      calls.count, 1, "an unsupported platform will not become supported by waiting")
  }

  func testGivesUpAfterTheLastAttempt() async {
    let calls = Counter()
    let fetcher = SearchAdsTokenFetcher(attempts: 3, delayMs: 0) {
      _ = calls.increment()
      throw SearchAdsError.transient
    }
    let token = await fetcher.token()
    XCTAssertNil(token)
    XCTAssertEqual(calls.count, 3, "bounded — a broken device must not retry forever")
  }

  func testZeroIdfaIsNotAnIdentifier() {
    // Apple returns the all-zero UUID when tracking is not authorised. Sending
    // it would make every unauthorised device look like the same device.
    XCTAssertEqual(ZERO_IDFA, "00000000-0000-0000-0000-000000000000")
    XCTAssertNil(AdvertisingIdentity().advertisingId, "simulator is not authorised")
  }

  func testLimitAdTrackingSeparatesDeniedFromOrganic() {
    // notDetermined is not a denial: the user has not decided, and reporting
    // limitAdTracking here would send a consent signal nobody gave.
    let identity = AdvertisingIdentity()
    if identity.status == .notDetermined {
      XCTAssertFalse(identity.limitAdTracking)
    }
  }
}

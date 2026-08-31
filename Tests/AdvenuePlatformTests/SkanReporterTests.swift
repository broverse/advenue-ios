import Foundation
import XCTest

@testable import AdvenueCore
@testable import AdvenuePlatform

private struct Boom: Error {}

final class SkanReporterTests: XCTestCase {
  /// The invariant that matters, and the reason the AdAttributionKit call is
  /// injectable at all.
  ///
  /// An AAK failure is the **expected** answer whenever no AAK-signed
  /// impression exists — most devices, most of the time. If it propagated, the
  /// caller would abandon a perfectly good SKAN value, never confirm it, and
  /// that window would report nothing for the rest of its life.
  func testAnAdAttributionKitFailureDoesNotFailTheUpdate() async {
    let reported = Locked<[String]>([])
    let reporter = StoreKitSkanReporter(
      onError: { context, _ in reported.mutate { $0.append(context) } },
      adAttributionUpdate: { _, _, _ in throw Boom() })

    // The SKAN half may legitimately fail on its own — a simulator answers
    // SKANErrorDomain 10, and a device with no ad impression can too. What must
    // never happen is the AAK failure BEING the reason, so the assertion is on
    // which error escapes, not on whether one does.
    do {
      try await reporter.update(fine: 10, coarse: .low, lockWindow: false)
    } catch is Boom {
      XCTFail("an AdAttributionKit failure must not fail the update")
    } catch {
      // A SKAN-side refusal is fine and is the caller's to handle.
    }

    XCTAssertTrue(
      reported.value.contains("skan.adAttributionKit"),
      "the failure must still be surfaced, just not fatal")
  }

  /// Both rails get the same value: an impression may be signed for either one,
  /// so choosing between them would silently halve coverage on iOS 17.4+.
  func testBothRailsReceiveTheSameValue() async {
    let seen = Locked<[SkanCall]>([])
    let reporter = StoreKitSkanReporter(
      adAttributionUpdate: { fine, coarse, lock in
        seen.mutate { $0.append(SkanCall(fine: fine, coarse: coarse, lock: lock)) }
      })

    // The SKAN half may refuse; what is under test is that AAK was handed the
    // same value on the way past.
    try? await reporter.update(fine: 42, coarse: .medium, lockWindow: true)

    XCTAssertEqual(seen.value, [SkanCall(fine: 42, coarse: .medium, lock: true)])
  }

  /// A run with nothing to report must still not throw: registration happens on
  /// every launch, including the ones where SKAN is unavailable.
  func testRegisterIsSafeEverywhere() {
    StoreKitSkanReporter().register()
  }
}

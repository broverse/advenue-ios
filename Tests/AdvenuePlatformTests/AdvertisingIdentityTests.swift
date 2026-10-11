import Foundation
import XCTest

@testable import AdvenuePlatform

final class AdvertisingIdentityTests: XCTestCase {
  /// Production reads this from a background `Task` (the enrichment
  /// collector), so the main-actor hop for the vendor id must work off the
  /// main thread: no deadlock, no trap. The simulator has a vendor id.
  func testVendorIdReadsFromABackgroundThread() async {
    let vendorId = await Task.detached { AdvertisingIdentity().vendorId }.value
    #if canImport(UIKit)
      XCTAssertNotNil(vendorId)
    #else
      XCTAssertNil(vendorId)
    #endif
  }

  /// The flush/foreground refresh hands the core one snapshot; the ATT status
  /// must be in it, read alongside the IDFA and limitAdTracking it explains.
  func testSnapshotsCarryTheAttStatus() {
    let identity = AdvertisingIdentity()
    XCTAssertEqual(identity.snapshot().attStatus, identity.status)
    XCTAssertEqual(identity.nonBlockingSnapshot().attStatus, identity.status)
  }
}

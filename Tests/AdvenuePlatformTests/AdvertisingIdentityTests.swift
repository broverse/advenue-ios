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
}

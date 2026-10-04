import Foundation
import XCTest

@testable import AdvenueCore
@testable import AdvenuePlatform

final class DeviceInfoTests: XCTestCase {
  /// Android has had this since its first commit; iOS was at zero references,
  /// and the field is what Meta CAPI extinfo is built from.
  func testCollectsWhatItCanAndOmitsTheRest() {
    let info = collectDeviceInfo()

    XCTAssertNotNil(info["model"])
    XCTAssertNotNil(info["locale"])
    XCTAssertNotNil(info["timezone"])
    XCTAssertNotNil(info["cpuCores"])

    // Whatever is present must be usable; nothing may be a placeholder zero,
    // because downstream that is indistinguishable from a measurement.
    if case .int(let cores)? = info["cpuCores"] { XCTAssertGreaterThan(cores, 0) }
    if case .int(let width)? = info["screenWidth"] { XCTAssertGreaterThan(width, 0) }
    if case .double(let storage)? = info["totalStorageGb"] {
      XCTAssertGreaterThan(storage, 0)
    }
  }

  /// `UIDevice.model` answers "iPhone" for every iPhone ever made. Meta's
  /// extinfo wants the hardware identifier, which is the only form that can
  /// segment anything.
  func testTheModelIsTheHardwareIdentifierNotTheFamily() {
    guard case .string(let model)? = collectDeviceInfo()["model"] else {
      return XCTFail("no model collected")
    }
    XCTAssertFalse(model.isEmpty)
    XCTAssertNotEqual(model, "iPhone", "that is the family, not the model")
    XCTAssertNotEqual(model, "unknown")
  }

  /// Production calls this from a background `Task` (`Advenue.start`
  /// submits it there), so the main-actor hop for the screen fields must work
  /// off the main thread: no deadlock, no trap, same fields.
  func testCollectsFromABackgroundThread() async {
    let info = await Task.detached { collectDeviceInfo() }.value

    XCTAssertNotNil(info["model"])
    #if canImport(UIKit)
      guard case .int(let width)? = info["screenWidth"] else {
        return XCTFail("no screenWidth collected off the main thread")
      }
      XCTAssertGreaterThan(width, 0)
    #endif
  }

  func testItEncodesAsEventProperties() throws {
    var event = ClientEvent(
      id: "i", deviceId: "d", type: "install", name: "install",
      timestamp: EventEncoding.iso8601(ms: 0), platform: "ios")
    event.properties = collectDeviceInfo()
    let json = try event.encodeCanonical()
    XCTAssertTrue(json.contains("\"model\""), json)
    XCTAssertFalse(json.contains("null"), "zod .optional() rejects null")
  }
}

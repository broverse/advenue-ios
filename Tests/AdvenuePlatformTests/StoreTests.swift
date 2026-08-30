import Foundation
import Security
import XCTest

@testable import AdvenueCore
@testable import AdvenuePlatform

final class StoreTests: XCTestCase {
  func testSuiteAndServiceNamesMatchTheRNSDK() {
    // The RN native module writes to UserDefaults(suiteName: "io.advenue.sdk")
    // and the Keychain service of the same name. A different name here orphans
    // every existing install when RN is inverted onto this SDK.
    XCTAssertEqual(ADVENUE_SUITE, "io.advenue.sdk")
    XCTAssertEqual(KeychainStore.service, "io.advenue.sdk")
  }

  func testUserDefaultsStoreRoundTrips() {
    let store = UserDefaultsStore()
    store.removeObject(forKey: "advenue.test")
    XCTAssertNil(store.string(forKey: "advenue.test"))
    store.set("v", forKey: "advenue.test")
    XCTAssertEqual(store.string(forKey: "advenue.test"), "v")
    store.removeObject(forKey: "advenue.test")
    XCTAssertNil(store.string(forKey: "advenue.test"))
  }

  // MARK: - The decision that matters

  /// This is the fix for the spec's identity hole, and it is a pure function
  /// so it is testable here. The Keychain ROUND TRIP is not: an unsigned
  /// XCTest bundle in the simulator has no keychain entitlement and every
  /// query answers errSecMissingEntitlement. That path needs a signed host app
  /// or a real device and is on the manual checklist — but the mapping below
  /// is where a wrong answer would invent a device, and it is covered.
  func testAbsentPermitsMinting() {
    XCTAssertEqual(KeychainStore.interpret(status: errSecItemNotFound, data: nil), .absent)
  }

  func testLockedDeviceIsUnavailableNotAbsent() {
    // The whole point. Before the first unlock after a reboot an
    // AfterFirstUnlock item answers errSecInteractionNotAllowed, and silent
    // push can background-launch the app in exactly that window. Reporting it
    // as .absent would mint a device id nobody has ever seen.
    XCTAssertEqual(
      KeychainStore.interpret(status: errSecInteractionNotAllowed, data: nil), .unavailable)
  }

  func testUnknownFailuresAreUnavailableTooNotAbsent() {
    // Fail closed: an unrecognised error is not evidence that no value exists.
    // errSecMissingEntitlement is what this very test bundle gets.
    XCTAssertEqual(
      KeychainStore.interpret(status: errSecMissingEntitlement, data: nil), .unavailable)
    XCTAssertEqual(KeychainStore.interpret(status: errSecAuthFailed, data: nil), .unavailable)
  }

  func testFoundReturnsTheStoredValue() {
    XCTAssertEqual(
      KeychainStore.interpret(status: errSecSuccess, data: Data("dev-1".utf8)), .found("dev-1"))
  }

  func testSuccessWithUnreadableDataIsAbsentNotAGarbageIdentity() {
    // A success whose payload is not UTF-8 is not an identity. Returning
    // .absent lets the caller mint a clean one rather than stamp events with
    // a corrupted string.
    XCTAssertEqual(KeychainStore.interpret(status: errSecSuccess, data: nil), .absent)
    XCTAssertEqual(
      KeychainStore.interpret(status: errSecSuccess, data: Data([0xFF, 0xFE])), .absent)
  }

  func testUnavailableIsNotAbsent() {
    XCTAssertNotEqual(SecureReadResult.unavailable, SecureReadResult.absent)
  }
}

import Foundation
import XCTest

@testable import AdvenueCore
@testable import AdvenuePlatform

/// A secure store whose answer the test dictates, so the locked path is
/// reachable without a locked device.
private final class StubSecure: SecureStore, @unchecked Sendable {
  var result: SecureReadResult
  private(set) var writes: [String: String] = [:]
  private(set) var deletes: [String] = []
  init(_ result: SecureReadResult) { self.result = result }
  func read(_ key: String) -> SecureReadResult { result }
  func write(_ value: String, forKey key: String) { writes[key] = value }
  func delete(_ key: String) { deletes.append(key) }
}

private final class Store: KeyValueStore, @unchecked Sendable {
  var values: [String: String] = [:]
  func string(forKey key: String) -> String? { values[key] }
  func set(_ value: String, forKey key: String) { values[key] = value }
  func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

private final class CountingUUIDs: UUIDSource, @unchecked Sendable {
  private var n = 0
  func next() -> String {
    n += 1
    return "minted-\(n)"
  }
}

final class IdentityTests: XCTestCase {
  func testReusesTheStoredDeviceId() {
    let secure = StubSecure(.found("existing-device"))
    let resolution = resolveIdentity(secure: secure, store: Store(), uuid: CountingUUIDs())
    XCTAssertEqual(resolution, .resolved(deviceId: "existing-device", installationId: "minted-1"))
    XCTAssertTrue(secure.writes.isEmpty, "an existing id must not be rewritten")
  }

  func testMintsOnlyWhenGenuinelyAbsent() {
    let secure = StubSecure(.absent)
    let resolution = resolveIdentity(secure: secure, store: Store(), uuid: CountingUUIDs())
    XCTAssertEqual(resolution, .resolved(deviceId: "minted-1", installationId: "minted-2"))
    XCTAssertEqual(secure.writes[DEVICE_ID_KEY], "minted-1")
  }

  func testDefersWhenTheKeychainIsLocked() {
    // The whole point. Before the first unlock after a reboot a silent push
    // can background-launch the app; minting here would stamp every event of
    // that launch with a device id nobody has ever seen.
    let secure = StubSecure(.unavailable)
    let store = Store()
    let resolution = resolveIdentity(secure: secure, store: store, uuid: CountingUUIDs())
    XCTAssertEqual(resolution, .deferred)
    XCTAssertTrue(secure.writes.isEmpty, "a locked keychain must not be written to")
    XCTAssertNil(
      store.values[INSTALLATION_ID_KEY],
      "and nothing downstream of the device id may be created either")
  }

  func testInstallationIdIsReusedWithinAnInstall() {
    let store = Store()
    store.values[INSTALLATION_ID_KEY] = "existing-install"
    let resolution = resolveIdentity(
      secure: StubSecure(.found("d")), store: store, uuid: CountingUUIDs())
    XCTAssertEqual(resolution, .resolved(deviceId: "d", installationId: "existing-install"))
  }

  func testTheTwoIdsLiveInDifferentStores() {
    // Reinstall detection rests on this asymmetry: the device id survives
    // uninstall because it is in the Keychain, the installation id does not
    // because it is in UserDefaults. If both moved to one store, a reinstall
    // would look like either a new device or an unchanged install.
    let secure = StubSecure(.absent)
    let store = Store()
    _ = resolveIdentity(secure: secure, store: store, uuid: CountingUUIDs())
    XCTAssertNotNil(secure.writes[DEVICE_ID_KEY])
    XCTAssertNil(store.values[DEVICE_ID_KEY], "the device id must not also land in UserDefaults")
    XCTAssertNotNil(store.values[INSTALLATION_ID_KEY])
  }
}

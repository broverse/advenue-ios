import AdvenueCore
import Foundation

/// Survives uninstall — Keychain.
public let DEVICE_ID_KEY = "advenue.device_id"
/// Dies with the app — UserDefaults.
public let INSTALLATION_ID_KEY = "advenue.installation_id"

public enum IdentityResolution: Equatable, Sendable {
  case resolved(deviceId: String, installationId: String)
  /// The Keychain could not be read. The caller waits for
  /// `protectedDataDidBecomeAvailable` rather than inventing an identity.
  case deferred
}

/// Resolves the pair the SDK stamps on every event.
///
/// The asymmetry is the design: `device_id` lives in the Keychain and survives
/// uninstall, `installation_id` lives in UserDefaults and does not. Reinstall
/// detection rests entirely on that difference, so neither half may quietly
/// move to the other store.
///
/// A locked Keychain returns `.deferred` and mints nothing. Treating it as
/// absent is what would stamp a whole background launch with a device id
/// belonging to no real device — reachable since #26 introduced silent push,
/// which can start the app before the first unlock after a reboot.
public func resolveIdentity(
  secure: any SecureStore,
  store: any KeyValueStore,
  uuid: any UUIDSource
) -> IdentityResolution {
  let deviceId: String
  switch secure.read(DEVICE_ID_KEY) {
  case .found(let existing):
    deviceId = existing
  case .unavailable:
    return .deferred
  case .absent:
    let minted = uuid.next()
    secure.write(minted, forKey: DEVICE_ID_KEY)
    deviceId = minted
  }

  let installationId: String
  if let existing = store.string(forKey: INSTALLATION_ID_KEY) {
    installationId = existing
  } else {
    installationId = uuid.next()
    store.set(installationId, forKey: INSTALLATION_ID_KEY)
  }

  return .resolved(deviceId: deviceId, installationId: installationId)
}

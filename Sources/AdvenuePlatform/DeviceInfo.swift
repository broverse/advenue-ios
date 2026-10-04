import AdvenueCore
import Foundation

#if canImport(UIKit)
  import UIKit
#endif

/// The app's own version (`CFBundleShortVersionString`) for every event's
/// top-level `appVersion`. Resolved by the SDK, never taken from the app: the
/// React Native 0.x layer filled it this way, and 1.0 relying on the config
/// instead left every event unversioned (2026-09-19). Nil when the bundle has
/// no version.
public func readAppVersion() -> String? {
  guard let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
    !short.isEmpty
  else { return nil }
  return short
}

/// Whether this process was launched into the background — background fetch,
/// a silent push, a location relaunch — rather than opened by the user. Read
/// through the runtime, not `UIApplication.shared`: that symbol is unavailable
/// in an app extension and merely referencing it there fails to link. False
/// wherever it cannot be known (an extension, off the main thread, macOS),
/// which keeps the pre-existing behaviour: the launch is a foreground.
public func readLaunchedInBackground() -> Bool {
  #if canImport(UIKit) && !os(watchOS)
    guard Thread.isMainThread, !Bundle.main.bundlePath.hasSuffix(".appex") else { return false }
    let selector = NSSelectorFromString("sharedApplication")
    guard UIApplication.responds(to: selector),
      let app = UIApplication.perform(selector)?.takeUnretainedValue() as? UIApplication
    else { return false }
    // On the main thread by the guard above, so this is a static fact for
    // the compiler rather than a runtime hop.
    return MainActor.assumeIsolated { app.applicationState == .background }
  #else
    return false
  #endif
}

/// Device metadata for Meta CAPI `extinfo`.
///
/// Best-effort per field: a field is **omitted**, never defaulted, when its
/// source is unavailable. A placeholder zero reaching the warehouse is
/// indistinguishable from a real measurement, which is worse than a gap — the
/// Android collector follows the same rule.
public func collectDeviceInfo() -> [String: AdvenueValue] {
  var info: [String: AdvenueValue] = [:]

  info["model"] = .string(hardwareModel())
  info["locale"] = .string(Locale.current.identifier)
  info["timezone"] = .string(TimeZone.current.identifier)
  info["cpuCores"] = .int(ProcessInfo.processInfo.processorCount)

  if let bundleId = Bundle.main.bundleIdentifier {
    info["packageName"] = .string(bundleId)
  }
  if let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
    info["shortVersion"] = .string(short)
  }
  if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
    info["longVersion"] = .string(build)
  }

  #if canImport(UIKit)
    // One hop for both reads: this runs on a background task in production.
    let (bounds, scale) = onMainSync { (UIScreen.main.bounds, UIScreen.main.scale) }
    info["screenWidth"] = .int(Int(bounds.width))
    info["screenHeight"] = .int(Int(bounds.height))
    info["screenDensity"] = .double(Double(scale))
  #endif

  if let attributes = try? FileManager.default.attributesOfFileSystem(
    forPath: NSHomeDirectory())
  {
    let gigabyte = 1024.0 * 1024.0 * 1024.0
    if let total = attributes[.systemSize] as? NSNumber {
      info["totalStorageGb"] = .double(total.doubleValue / gigabyte)
    }
    if let free = attributes[.systemFreeSize] as? NSNumber {
      info["freeStorageGb"] = .double(free.doubleValue / gigabyte)
    }
  }

  return info
}

/// The hardware identifier (`iPhone16,2`), which is what Meta's extinfo wants —
/// `UIDevice.model` answers "iPhone" for every iPhone ever made and is useless
/// for segmentation.
private func hardwareModel() -> String {
  var systemInfo = utsname()
  uname(&systemInfo)
  let mirror = Mirror(reflecting: systemInfo.machine)
  let identifier = mirror.children.reduce(into: "") { partial, element in
    guard let value = element.value as? Int8, value != 0 else { return }
    partial.append(Character(UnicodeScalar(UInt8(value))))
  }
  return identifier.isEmpty ? "unknown" : identifier
}

import AdvenueCore
import Foundation

/// Reads IAB TCF v2 from the **standard** `UserDefaults`, which is where a
/// TCF-compliant CMP writes per the spec — deliberately not our own suite.
/// Reading our suite instead would report no consent data for every app on
/// earth, and do it silently.
public func readTcf(_ defaults: UserDefaults = .standard) -> Consent? {
  // `object(forKey:)` rather than `integer(forKey:)`: the latter answers 0 for
  // a missing key, which would turn "the CMP has not said" into "GDPR does not
  // apply". Those are different, and the difference decides whether a user is
  // gated.
  let raw = defaults.object(forKey: "IABTCF_gdprApplies")
  let gdprApplies = (raw as? NSNumber)?.intValue
  let purposeConsents = defaults.string(forKey: "IABTCF_PurposeConsents")

  if raw == nil && purposeConsents == nil { return nil }
  return tcfToConsent(gdprApplies: gdprApplies, purposeConsents: purposeConsents)
}

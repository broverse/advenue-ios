import Foundation

/// Maps raw IAB TCF v2 CMP data to the DMA `Consent` shape, per Google's EU
/// User Consent Policy reading of the TCF purposes:
///
/// - `ad_storage` ← Purpose 1
/// - `ad_user_data` ← Purposes 1 **and** 7
/// - `ad_personalization` ← Purposes 3 **and** 4
///
/// Returns nil when `gdprApplies` is neither 0 nor 1. Absent consent must stay
/// absent: a guessed value is forwarded to ad networks as a real signal, and a
/// signal invented on a user's behalf is the one thing consent plumbing must
/// never do.
public func tcfToConsent(gdprApplies: Int?, purposeConsents: String?) -> Consent? {
  guard gdprApplies == 0 || gdprApplies == 1 else { return nil }
  if gdprApplies == 0 { return Consent(isUserSubjectToGDPR: false) }

  let consents = Array(purposeConsents ?? "")
  func purpose(_ n: Int) -> Bool { n <= consents.count && consents[n - 1] == "1" }

  return Consent(
    isUserSubjectToGDPR: true,
    hasConsentForDataUsage: purpose(1) && purpose(7),
    hasConsentForAdsPersonalization: purpose(3) && purpose(4),
    hasConsentForAdStorage: purpose(1))
}

/// Meta AEM `campaign_ids`, extracted from an `al_applink_data` payload.
///
/// The input is the ALREADY percent-decoded query value: decoding again would
/// corrupt a blob containing '%'. Meta does not publicly document the schema, so
/// both shapes seen in the wild are accepted, top level first.
///
/// The blob is opaque, Meta-encrypted, non-user metadata and is returned
/// verbatim — never trimmed or re-encoded. The 2048 cap is URL hygiene; the
/// server re-validates, because an SDK-side cap is advisory at a trust boundary.
public func extractAemCampaignIds(_ alApplinkData: String) -> String? {
  guard let data = alApplinkData.data(using: .utf8),
    let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { return nil }

  let top = parsed["campaign_ids"] as? String
  let nested = (parsed["extras"] as? [String: Any])?["campaign_ids"] as? String
  guard let value = (top?.isEmpty == false ? top : nil) ?? (nested?.isEmpty == false ? nested : nil)
  else { return nil }

  return value.count <= 2048 ? value : nil
}

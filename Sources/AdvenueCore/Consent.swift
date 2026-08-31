import Foundation

/// Granular ad-platform consent (Google DMA), forwarded to Google and Meta by
/// server-side postbacks as `gdpr_applies`, `ad_user_data`, `ad_personalization`
/// and `ad_storage`.
///
/// Three of the four fields are optional, and that is the point rather than
/// laxity: **"not stated" is not "denied".** A CMP that has not asked about ad
/// storage yet must not have `false` invented on its behalf, because downstream
/// that is a recorded refusal. The encoder omits nil, which is what keeps the
/// distinction on the wire.
public struct Consent: Codable, Equatable, Sendable {
  public var isUserSubjectToGDPR: Bool
  public var hasConsentForDataUsage: Bool?
  public var hasConsentForAdsPersonalization: Bool?
  public var hasConsentForAdStorage: Bool?

  public init(
    isUserSubjectToGDPR: Bool,
    hasConsentForDataUsage: Bool? = nil,
    hasConsentForAdsPersonalization: Bool? = nil,
    hasConsentForAdStorage: Bool? = nil
  ) {
    self.isUserSubjectToGDPR = isUserSubjectToGDPR
    self.hasConsentForDataUsage = hasConsentForDataUsage
    self.hasConsentForAdsPersonalization = hasConsentForAdsPersonalization
    self.hasConsentForAdStorage = hasConsentForAdStorage
  }
}

/// Validates a push token against the server's bound and charset.
///
/// Rejecting here costs one dropped registration; letting it through costs
/// every event in the batch it would have ridden in, because ingest parses a
/// batch as a whole.
public func isValidPushToken(_ token: String) -> Bool {
  guard !token.isEmpty, token.count <= 512 else { return false }
  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_:.-"))
  return token.unicodeScalars.allSatisfy { allowed.contains($0) }
}

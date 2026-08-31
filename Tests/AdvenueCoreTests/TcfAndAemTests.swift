import Foundation
import XCTest

@testable import AdvenueCore

final class TcfAndAemTests: XCTestCase {
  /// Absent consent must stay absent. A guessed value is forwarded to ad
  /// networks as a real signal, and inventing one on a user's behalf is the one
  /// thing consent plumbing must never do.
  func testAnUnknownGdprAppliesYieldsNoConsentAtAll() {
    XCTAssertNil(tcfToConsent(gdprApplies: nil, purposeConsents: "1111111111"))
    XCTAssertNil(tcfToConsent(gdprApplies: 2, purposeConsents: "1111111111"))
  }

  func testGdprNotApplyingIsAPositiveStatement() {
    let consent = tcfToConsent(gdprApplies: 0, purposeConsents: nil)
    XCTAssertEqual(consent?.isUserSubjectToGDPR, false)
    XCTAssertNil(consent?.hasConsentForAdStorage, "nothing else is claimed")
  }

  /// Google's reading: ad_storage ← P1, ad_user_data ← P1+P7, ads ← P3+P4.
  func testThePurposeMappingFollowsGooglesPolicy() {
    let storageOnly = tcfToConsent(gdprApplies: 1, purposeConsents: "1000000000")
    XCTAssertEqual(storageOnly?.hasConsentForAdStorage, true)
    XCTAssertEqual(storageOnly?.hasConsentForDataUsage, false)

    XCTAssertEqual(
      tcfToConsent(gdprApplies: 1, purposeConsents: "1000001000")?.hasConsentForDataUsage, true)
    XCTAssertEqual(
      tcfToConsent(gdprApplies: 1, purposeConsents: "0011000000")?
        .hasConsentForAdsPersonalization, true)
  }

  /// Both purposes are required; one alone does not grant.
  func testAPartialPairDoesNotGrant() {
    XCTAssertEqual(
      tcfToConsent(gdprApplies: 1, purposeConsents: "0000001000")?.hasConsentForDataUsage, false)
    XCTAssertEqual(
      tcfToConsent(gdprApplies: 1, purposeConsents: "0010000000")?
        .hasConsentForAdsPersonalization, false)
  }

  func testAShortConsentStringDeniesRatherThanCrashing() {
    XCTAssertEqual(
      tcfToConsent(gdprApplies: 1, purposeConsents: "1")?.hasConsentForDataUsage, false)
    XCTAssertEqual(
      tcfToConsent(gdprApplies: 1, purposeConsents: nil)?.hasConsentForAdStorage, false)
  }

  func testAemCampaignIdsComeFromEitherShapeTopLevelFirst() {
    XCTAssertEqual(extractAemCampaignIds(#"{"campaign_ids":"blob-a"}"#), "blob-a")
    XCTAssertEqual(extractAemCampaignIds(#"{"extras":{"campaign_ids":"blob-b"}}"#), "blob-b")
    XCTAssertEqual(
      extractAemCampaignIds(#"{"campaign_ids":"top","extras":{"campaign_ids":"nested"}}"#), "top")
  }

  /// The blob is opaque and Meta-encrypted: returned verbatim, never cleaned up.
  func testTheBlobIsReturnedVerbatim() {
    XCTAssertEqual(extractAemCampaignIds(#"{"campaign_ids":"AB+/=%ZZ"}"#), "AB+/=%ZZ")
  }

  func testMalformedOrOversizedPayloadsYieldNothing() {
    XCTAssertNil(extractAemCampaignIds("{not json"))
    XCTAssertNil(extractAemCampaignIds(#"{"campaign_ids":""}"#))
    XCTAssertNil(extractAemCampaignIds(#"{"campaign_ids":123}"#))
    XCTAssertNil(
      extractAemCampaignIds("{\"campaign_ids\":\"\(String(repeating: "x", count: 2049))\"}"))
  }
}

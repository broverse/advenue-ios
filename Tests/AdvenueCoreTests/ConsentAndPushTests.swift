import Foundation
import XCTest

@testable import AdvenueCore

final class ConsentAndPushTests: XCTestCase {
  private func engine(_ store: MemoryStore) -> AdvenueEngine {
    AdvenueEngine(
      config: EngineConfig(apiKey: "apk_test", platform: "ios", deviceId: "d1"),
      store: store, clock: FixedClock(ms: 0),
      scheduler: RecordingScheduler(), uuid: SequentialUUIDs(prefix: "ev"))
  }

  func testConsentDataRidesEverySubsequentEvent() async {
    let e = engine(MemoryStore())
    await e.setConsentData(Consent(isUserSubjectToGDPR: true, hasConsentForDataUsage: true))
    await e.track("purchase")

    let consent = await e.pendingEvents().first?.consent
    XCTAssertEqual(consent?.isUserSubjectToGDPR, true)
    XCTAssertEqual(consent?.hasConsentForDataUsage, true)
  }

  /// Persisted under the key the RN SDK already uses, so the inversion reads
  /// what it wrote — and so a relaunch does not silently drop a stated
  /// preference.
  func testConsentDataSurvivesARestart() async {
    let store = MemoryStore()
    await engine(store).setConsentData(
      Consent(isUserSubjectToGDPR: true, hasConsentForAdStorage: false))

    let reborn = engine(store)
    let consent = await reborn.getConsentData()
    XCTAssertEqual(consent?.isUserSubjectToGDPR, true)
    XCTAssertEqual(consent?.hasConsentForAdStorage, false)
    XCTAssertNil(consent?.hasConsentForDataUsage, "an unset field must stay unset")
  }

  /// "Not stated" is not "denied". A CMP that has not asked about ad storage
  /// must not have false invented on its behalf, because downstream that is a
  /// recorded refusal.
  func testAnUnsetOptionalIsOmittedNotSentAsFalse() async throws {
    let e = engine(MemoryStore())
    await e.setConsentData(Consent(isUserSubjectToGDPR: true))
    await e.track("purchase")

    let json = try await e.pendingEvents().first!.encodeCanonical()
    XCTAssertTrue(json.contains(#""consent":{"isUserSubjectToGDPR":true}"#), json)
    XCTAssertFalse(json.contains("hasConsentForAdStorage"))
  }

  /// #26's uninstall measurement has no iOS producer without this. The token
  /// rides install and session events only: it is ~180 bytes and the registry
  /// needs it periodically, not on every custom event in a 100-event batch.
  func testThePushTokenRidesLifecycleEventsOnly() async {
    let e = engine(MemoryStore())
    await e.setPushToken("apns-token-123")
    await e.trackInstall(adservicesToken: nil)
    await e.track("session_start", type: "session")
    await e.track("purchase")

    let events = await e.pendingEvents()
    XCTAssertEqual(events[0].pushToken, "apns-token-123")
    XCTAssertEqual(events[0].pushProvider, "apns")
    XCTAssertEqual(events[1].pushToken, "apns-token-123")
    XCTAssertNil(events[2].pushToken, "a custom event must not carry it")
  }

  /// An iOS app using Firebase Messaging holds an FCM token; probing it against
  /// APNs would look like an uninstall on every device.
  func testTheProviderCanBeOverridden() async {
    let e = engine(MemoryStore())
    await e.setPushToken("fcm-on-ios", provider: "fcm")
    await e.trackInstall(adservicesToken: nil)
    let provider = await e.pendingEvents().first?.pushProvider
    XCTAssertEqual(provider, "fcm")
  }

  /// Mirrors the server's bound and charset: rejecting here costs one dropped
  /// registration instead of every event in the batch it would have ridden in.
  func testAMalformedTokenIsRejected() async {
    let reported = Locked<[String]>([])
    let e = AdvenueEngine(
      config: EngineConfig(apiKey: "apk_test", platform: "ios", deviceId: "d1"),
      store: MemoryStore(), clock: FixedClock(ms: 0),
      scheduler: RecordingScheduler(), uuid: SequentialUUIDs(prefix: "ev"),
      onError: { context, _ in reported.mutate { $0.append(context) } })

    await e.setPushToken("has spaces and *")
    await e.trackInstall(adservicesToken: nil)

    let token = await e.pendingEvents().first?.pushToken
    XCTAssertNil(token)
    XCTAssertTrue(reported.value.contains("push.setPushToken"))
  }

  func testAnOverLongTokenIsRejected() async {
    let e = engine(MemoryStore())
    await e.setPushToken(String(repeating: "a", count: 513))
    await e.trackInstall(adservicesToken: nil)
    let token = await e.pendingEvents().first?.pushToken
    XCTAssertNil(token)
  }

  /// B6: 128 üstü userId batch'i 400'e düşürür — reddedilir, persist edilmez.
  func testAnOverLongUserIdIsRejected() async {
    let e = engine(MemoryStore())
    await e.setUserId(String(repeating: "u", count: 129))
    await e.track("purchase")
    let userId = await e.pendingEvents().first?.customerUserId
    XCTAssertNil(userId)
  }
}

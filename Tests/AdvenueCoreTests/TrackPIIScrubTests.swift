import Foundation
import XCTest

@testable import AdvenueCore

/// M2: track properties PII scrubbing. Varsayılan-açık scrub, ham e-posta ve
/// telefon değerlerinin ağ yüküne çıkmasını engeller.
final class TrackPIIScrubTests: XCTestCase {
  private func engine(
    _ store: MemoryStore, piiScrubEnabled: Bool = true
  ) -> AdvenueEngine {
    AdvenueEngine(
      config: EngineConfig(
        apiKey: "apk_test", platform: "ios", deviceId: "d1",
        requireConsent: false, piiScrubEnabled: piiScrubEnabled),
      store: store, clock: FixedClock(ms: 0),
      scheduler: RecordingScheduler(), uuid: SequentialUUIDs(prefix: "ev"))
  }

  func testPiiTasiyanPropertiesAgYukundeHamGorunmemeli() async throws {
    let e = engine(MemoryStore())
    let rawEmail = "kullanici.ornek42@example.com"
    let rawPhone = "+90 532 123 45 67"
    _ = await e.track(
      "signup",
      properties: [
        "email": .string(rawEmail),
        "phone": .string(rawPhone),
        "plan": .string("gold"),
      ])
    let pending = await e.pendingEvents()
    XCTAssertEqual(pending.count, 1)
    let wire = try XCTUnwrap(pending.first).encodeCanonical()
    XCTAssertFalse(
      wire.contains(rawEmail), "ham e-posta ağ yükünde yer almamalı")
    XCTAssertFalse(
      wire.contains(rawPhone), "ham telefon ağ yükünde yer almamalı")
    XCTAssertTrue(
      wire.contains("gold"), "PII olmayan property korunmalı")
  }

  func testScrubPiiOlmayanDegerlereDokunmamali() async throws {
    let e = engine(MemoryStore())
    _ = await e.track(
      "aem",
      properties: [
        "campaignIds": .string("blob-seam"),
        "sourceUrlHash": .string(
          "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"),
        "date": .string("2026-09-08"),
        "appVersion": .string("1.10.0"),
      ])
    let pending = await e.pendingEvents()
    let props = try XCTUnwrap(pending.first?.properties)
    XCTAssertEqual(props["campaignIds"], .string("blob-seam"))
    XCTAssertNotNil(props["sourceUrlHash"], "hex hash PII değildir, korunmalı")
    XCTAssertEqual(props["date"], .string("2026-09-08"))
    XCTAssertEqual(props["appVersion"], .string("1.10.0"))
  }

  func testScrubVarsayilanAcikOptOutAyri() async throws {
    let rawEmail = "kullanici.ornek42@example.com"

    let defaultEngine = engine(MemoryStore())
    _ = await defaultEngine.track("s", properties: ["email": .string(rawEmail)])
    let defaultPending = await defaultEngine.pendingEvents()
    let defaultWire = try XCTUnwrap(defaultPending.first).encodeCanonical()
    XCTAssertFalse(
      defaultWire.contains(rawEmail), "scrub varsayılan-açık olmalı")

    let optOutEngine = engine(MemoryStore(), piiScrubEnabled: false)
    _ = await optOutEngine.track("s", properties: ["email": .string(rawEmail)])
    let optOutPending = await optOutEngine.pendingEvents()
    let optOutWire = try XCTUnwrap(optOutPending.first).encodeCanonical()
    XCTAssertTrue(
      optOutWire.contains(rawEmail), "opt-out açıkça kapatıldığında ham değer korunur")
  }
}

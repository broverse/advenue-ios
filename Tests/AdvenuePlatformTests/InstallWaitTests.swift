import Foundation
import XCTest

@testable import Advenue
@testable import AdvenueCore
@testable import AdvenuePlatform

/// The install flow's ATT wait, driven through the `runInstallFlow` seam:
/// injected submit/sources/status/sleep, no Keychain, no real ATT, no
/// network. `start` itself can't be driven here — it touches the real
/// Keychain, which unsigned runners can't read.
final class InstallWaitTests: XCTestCase {
  override func tearDown() {
    Advenue.shutdown()
    super.tearDown()
  }

  private struct FlowResult {
    var commands: [Command]
    var events: [String]
  }

  private func kind(_ command: Command) -> String {
    switch command {
    case .setIdentity: return "setIdentity"
    case .setDeviceInfo: return "setDeviceInfo"
    case .setConsentData: return "setConsentData"
    case .trackInstall: return "trackInstall"
    case .flush: return "flush"
    default: return "other"
    }
  }

  /// Drives the flow with a scripted ATT status reader. `events` records the
  /// interleaving — every status read, sleep and enrichment read — so tests
  /// can assert the IDFA was read AFTER the wait, not before it.
  private func runFlow(
    statusValues: [TrackingAuthorization],
    attWaitMs: Int,
    installOwed: Bool,
    idfa: String?
  ) async -> FlowResult {
    let events = Locked<[String]>([])
    let idx = Locked(0)
    let reader: @Sendable () -> TrackingAuthorization = {
      events.mutate { $0.append("status") }
      var v = TrackingAuthorization.notDetermined
      idx.mutate { i in v = statusValues[min(i, statusValues.count - 1)]; i += 1 }
      return v
    }
    let sources = EnrichmentSources(
      searchAdsToken: { nil },
      advertisingId: {
        events.mutate { $0.append("enrich") }
        return (idfa: idfa, vendorId: "VENDOR-1")
      },
      appInstanceId: { nil },
      attestation: { nil },
      limitAdTracking: { false })
    let submitted = Locked<[Command]>([])
    await runInstallFlow(
      submit: { cmd in submitted.mutate { $0.append(cmd) } },
      sources: sources,
      attStatus: reader,
      attWaitMs: attWaitMs,
      installOwed: installOwed,
      deviceInfo: { ["model": .string("test")] },
      tcf: { nil },
      deadlineMs: 100,
      sleep: { _ in events.mutate { $0.append("sleep") } },
      log: { _ in })
    return FlowResult(commands: submitted.value, events: events.value)
  }

  func testInstallWaitsForAttThenCarriesResolvedIdfa() async {
    let result = await runFlow(
      statusValues: [.notDetermined, .notDetermined, .authorized],
      attWaitMs: 60_000, installOwed: true, idfa: "IDFA-POST-WAIT")

    XCTAssertEqual(
      result.commands.map(kind),
      ["setIdentity", "setDeviceInfo", "trackInstall", "flush"])
    guard case .setIdentity(let idfa, _, _, _) = result.commands.first else {
      return XCTFail("the first submit must be the resolved identity")
    }
    XCTAssertEqual(idfa, "IDFA-POST-WAIT")
    // Gate read + two poll reads; one sleep between the undetermined polls.
    XCTAssertEqual(result.events.filter { $0 == "status" }.count, 3)
    XCTAssertEqual(result.events.filter { $0 == "sleep" }.count, 1)
    // The ordering that makes the feature work: enrichment read the IDFA
    // after the resolving poll, not at initialize.
    let lastStatus = result.events.lastIndex(of: "status")!
    let enrichAt = result.events.firstIndex(of: "enrich")!
    XCTAssertGreaterThan(enrichAt, lastStatus)
  }

  func testNoWaitWhenAlreadyAuthorized() async {
    let result = await runFlow(
      statusValues: [.authorized], attWaitMs: 60_000,
      installOwed: true, idfa: "IDFA-1")

    XCTAssertFalse(result.events.contains("sleep"), "a determined status never waits")
    XCTAssertEqual(result.events.filter { $0 == "status" }.count, 1, "gate read only")
    guard case .setIdentity(let idfa, _, _, _) = result.commands.first else {
      return XCTFail("the first submit must be the identity")
    }
    XCTAssertEqual(idfa, "IDFA-1")
  }

  func testTimeoutSendsInstallWithoutIdfa() async {
    let result = await runFlow(
      statusValues: [.notDetermined], attWaitMs: 1_000,
      installOwed: true, idfa: nil)

    XCTAssertTrue(result.events.contains("sleep"), "the timeout must actually be waited out")
    XCTAssertEqual(
      result.commands.map(kind),
      ["setIdentity", "setDeviceInfo", "trackInstall", "flush"],
      "a timeout costs enrichment, never the install")
    guard case .setIdentity(let idfa, _, _, _) = result.commands.first else {
      return XCTFail("the first submit must be the identity")
    }
    XCTAssertNil(idfa)
  }

  func testZeroIntervalNeverReadsStatus() async {
    let result = await runFlow(
      statusValues: [.authorized], attWaitMs: 0,
      installOwed: true, idfa: "IDFA-1")

    XCTAssertFalse(result.events.contains("status"), "a disabled wait reads nothing")
    XCTAssertEqual(
      result.commands.map(kind),
      ["setIdentity", "setDeviceInfo", "trackInstall", "flush"])
  }

  func testNoWaitWhenInstallAlreadySent() async {
    let result = await runFlow(
      statusValues: [.notDetermined], attWaitMs: 60_000,
      installOwed: false, idfa: nil)

    XCTAssertFalse(result.events.contains("status"), "later launches never wait")
    XCTAssertEqual(
      result.commands.map(kind),
      ["setIdentity", "setDeviceInfo", "trackInstall", "flush"])
  }

  func testHoldCoversWaitPlusEnrichment() {
    XCTAssertEqual(
      installHoldMs(attWaitSec: 0),
      INSTALL_WINDOW_MS + INSTALL_HOLD_MARGIN_MS,
      "no wait means exactly the old hold")
    XCTAssertEqual(installHoldMs(attWaitSec: 60), 65_000)
  }

  func testCancelPreventsAllSubmits() async {
    let submitted = Locked<[Command]>([])
    let sources = EnrichmentSources(
      searchAdsToken: { nil },
      advertisingId: { (idfa: nil, vendorId: nil) },
      appInstanceId: { nil },
      attestation: { nil },
      limitAdTracking: { false })
    let task = Task {
      await runInstallFlow(
        submit: { cmd in submitted.mutate { $0.append(cmd) } },
        sources: sources,
        attStatus: { .notDetermined },
        attWaitMs: 120_000,
        installOwed: true,
        deviceInfo: { [:] },
        tcf: { nil },
        deadlineMs: 100,
        sleep: { ms in try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) },
        log: { _ in })
    }
    task.cancel()
    await task.value
    XCTAssertTrue(submitted.value.isEmpty, "a cancelled install submits nothing")
  }

  /// The clamp report runs before the Keychain gate in `start`, so this holds
  /// on every runner — signed or not, deferred or resolved.
  func testClampedIntervalIsReported() {
    for interval in [-5, 600] {
      let contexts = Locked<[String]>([])
      Advenue.initialize(
        AdvenueConfig(
          apiKey: "apk_live_x",
          onError: { context, _ in contexts.mutate { $0.append(context) } },
          attConsentWaitingInterval: interval))
      XCTAssertTrue(
        contexts.value.contains("config.clamped:attConsentWaitingInterval"),
        "interval \(interval) must be clamped and reported")
      Advenue.shutdown()
    }
  }
}

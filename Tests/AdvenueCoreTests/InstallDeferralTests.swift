import Foundation
import XCTest

@testable import AdvenueCore

/// Follow-ups U2: under requireConsent a withdrawal keeps a still-queued
/// install (without its identifiers) instead of dropping it for good, and a
/// grant re-sends it once. The conformance vectors
/// `consent/withdrawal-keeps-install*` pin the cross-platform contract; these
/// cover what only the iOS engine has (attestation, the re-attestation hook,
/// reset) and the field-level stripping.
final class InstallDeferralTests: XCTestCase {
  private let pushToken = String(repeating: "ab", count: 32)

  private func engine(
    _ store: MemoryStore, clock: MutableClock = MutableClock(),
    transport: ScriptedTransport? = nil, uuidPrefix: String = "ev"
  ) -> AdvenueEngine {
    AdvenueEngine(
      config: EngineConfig(
        apiKey: "apk_test", platform: "ios", deviceId: "d1", requireConsent: true),
      store: store, clock: clock, scheduler: RecordingScheduler(),
      uuid: SequentialUUIDs(prefix: uuidPrefix), transport: transport)
  }

  /// An install queued with every consent-gated field set, then withdrawn.
  private func withdrawnInstall(_ e: AdvenueEngine) async -> ClientEvent {
    await e.setConsent(true)
    await e.setUserId("user-1")
    await e.setIdentity(idfa: "idfa-1", vendorId: "idfv-1", appInstanceId: "fai-1")
    await e.setConsentData(Consent(isUserSubjectToGDPR: true, hasConsentForDataUsage: true))
    await e.setPushToken(pushToken)
    let accepted = await e.trackInstall(
      adservicesToken: "ads-tok", properties: ["k": .string("v")],
      attestation: AttestationResult(keyId: "key-1", attestationObject: "att-1"),
      attestationChallenge: "chal-1")
    XCTAssertTrue(accepted)
    await e.track("a")
    let install = await e.pendingEvents().first { $0.type == "install" }!
    XCTAssertEqual(install.attestationToken, "att-1", "precondition: attested install")
    await e.setConsent(false)
    return install
  }

  func testAWithdrawalKeepsTheQueuedInstallWithoutItsGatedFields() async throws {
    let store = MemoryStore()
    let e = engine(store)
    let install = await withdrawnInstall(e)

    let pending = await e.pendingEvents()
    XCTAssertTrue(pending.isEmpty, "every other buffered event is still dropped (D6)")
    XCTAssertNil(store.raw(INSTALL_SENT_KEY), "the install is owed again")

    let raw = try XCTUnwrap(store.raw(INSTALL_DEFERRED_KEY))
    let kept = try JSONDecoder().decode(ClientEvent.self, from: Data(raw.utf8))
    XCTAssertEqual(kept.id, install.id)
    XCTAssertEqual(kept.timestamp, install.timestamp)
    XCTAssertEqual(kept.adservicesToken, "ads-tok")
    XCTAssertEqual(kept.properties?["k"], .string("v"))
    XCTAssertNil(kept.idfa)
    XCTAssertNil(kept.vendorId)
    XCTAssertNil(kept.appInstanceId)
    XCTAssertNil(kept.customerUserId)
    XCTAssertNil(kept.consent)
    XCTAssertNil(kept.pushToken)
    XCTAssertNil(kept.pushProvider)
    XCTAssertNil(kept.attestationToken)
    XCTAssertNil(kept.attestationType)
    XCTAssertNil(kept.attestationKeyId)
    XCTAssertNil(kept.attestationChallenge)
    for field in ["idfa", "customerUserId", "attestationToken", "consent", "pushToken"] {
      XCTAssertFalse(raw.contains("\"\(field)\""), "\(field) persisted")
    }
  }

  /// A grant re-enqueues it first, same id and timestamp, with the identifiers
  /// collected now — and without the attestation made before the withdrawal.
  func testAGrantReEnqueuesTheKeptInstallFirstWithFreshIdentifiers() async throws {
    let store = MemoryStore()
    let clock = MutableClock()
    let e = engine(store, clock: clock)
    let install = await withdrawnInstall(e)
    clock.ms += 3_600_000

    await e.setUserId("user-2")
    await e.setIdentity(idfa: "idfa-2", vendorId: "idfv-2", appInstanceId: "fai-2")
    await e.track("before-grant")  // refused: consent is withheld
    await e.setConsent(true)
    await e.track("after-grant")

    let pending = await e.pendingEvents()
    XCTAssertEqual(pending.map(\.type), ["install", "custom"])
    let resent = pending[0]
    XCTAssertEqual(resent.id, install.id)
    XCTAssertEqual(resent.timestamp, install.timestamp)
    XCTAssertEqual(resent.customerUserId, "user-2")
    XCTAssertEqual(resent.idfa, "idfa-2")
    XCTAssertEqual(resent.vendorId, "idfv-2")
    XCTAssertEqual(resent.appInstanceId, "fai-2")
    XCTAssertEqual(resent.pushToken, pushToken)
    XCTAssertNotNil(resent.consent)
    XCTAssertEqual(resent.adservicesToken, "ads-tok")
    XCTAssertNil(resent.attestationToken, "no re-attestation was armed")
    XCTAssertEqual(store.raw(INSTALL_SENT_KEY), "1")
    XCTAssertNil(store.raw(INSTALL_DEFERRED_KEY))
  }

  /// Review Focus 4: withdraw, grant, withdraw, grant sends exactly one install.
  func testWithdrawGrantWithdrawGrantSendsExactlyOneInstall() async {
    let store = MemoryStore()
    let transport = ScriptedTransport([])
    let e = engine(store, transport: transport)
    let install = await withdrawnInstall(e)
    await e.setConsent(true)
    await e.setConsent(false)
    await e.setConsent(true)
    await e.flush()
    // And once more after it left: nothing is kept, nothing re-sent.
    await e.setConsent(false)
    XCTAssertNil(store.raw(INSTALL_DEFERRED_KEY))
    XCTAssertEqual(store.raw(INSTALL_SENT_KEY), "1")
    await e.setConsent(true)
    await e.flush()

    let installs = await transport.sent.filter { $0.type == "install" }
    XCTAssertEqual(installs.map(\.id), [install.id])
  }

  /// With a re-attestation armed (the facade arms it under requireConsent),
  /// the grant holds the kept install for it and the D7 release carries it.
  func testAnArmedReattestationRunsOnGrantAndRidesTheKeptInstall() async throws {
    let store = MemoryStore()
    let transport = ScriptedTransport([])
    let e = engine(store, transport: transport)
    let starts = Locked(0)
    await e.armInstallReattestation(holdMs: 10_000) { starts.mutate { $0 += 1 } }
    let install = await withdrawnInstall(e)

    await e.setConsent(true)
    XCTAssertEqual(starts.value, 1, "the grant starts one re-attestation")
    var pending = await e.pendingEvents()
    XCTAssertTrue(pending.isEmpty, "the install waits for its attestation")
    await e.flush()
    var requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)

    await e.releaseDeferredInstall(
      attestation: AttestationResult(keyId: "key-2", attestationObject: "att-2"),
      attestationChallenge: "chal-2")
    pending = await e.pendingEvents()
    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(pending.first?.id, install.id)
    XCTAssertEqual(pending.first?.attestationToken, "att-2")
    XCTAssertEqual(pending.first?.attestationKeyId, "key-2")
    XCTAssertEqual(pending.first?.attestationChallenge, "chal-2")

    // A grant with nothing kept starts no attestation.
    await e.flush()
    await e.setConsent(false)
    await e.setConsent(true)
    XCTAssertEqual(starts.value, 1)
    requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
  }

  /// A relaunch while withheld: the launch's install flow (D7) defers its
  /// install and attestation; the grant releases ONE install, the kept one.
  func testARelaunchedInstallFlowReleasesTheKeptInstallNotASecondOne() async throws {
    let store = MemoryStore()
    let clock = MutableClock()
    let first = engine(store, clock: clock, uuidPrefix: "first")
    let install = await withdrawnInstall(first)

    clock.ms += 86_400_000
    let e = engine(store, clock: clock, uuidPrefix: "second")
    await e.beginInstall(holdMs: 5_000)
    await e.awaitInstallAttestation(holdMs: 5_000)
    let accepted = await e.trackInstall(adservicesToken: "ads-fresh")
    XCTAssertFalse(accepted)
    var pending = await e.pendingEvents()
    XCTAssertTrue(pending.isEmpty)
    XCTAssertNotNil(store.raw(INSTALL_DEFERRED_KEY), "kept across the relaunch")

    await e.setConsent(true)
    await e.releaseDeferredInstall(
      attestation: AttestationResult(keyId: "key-3", attestationObject: "att-3"),
      attestationChallenge: "chal-3")

    pending = await e.pendingEvents()
    XCTAssertEqual(pending.filter { $0.type == "install" }.count, 1)
    XCTAssertEqual(pending.first?.id, install.id)
    XCTAssertEqual(pending.first?.timestamp, install.timestamp)
    XCTAssertEqual(pending.first?.attestationToken, "att-3")
    XCTAssertNil(store.raw(INSTALL_DEFERRED_KEY))
  }

  /// A withdrawal after the install left keeps nothing: it was delivered.
  func testAWithdrawalAfterTheInstallLeftKeepsNothing() async {
    let store = MemoryStore()
    let e = engine(store, transport: ScriptedTransport([]))
    await e.setConsent(true)
    await e.trackInstall(adservicesToken: nil)
    await e.flush()
    await e.setConsent(false)
    XCTAssertNil(store.raw(INSTALL_DEFERRED_KEY))
    XCTAssertEqual(store.raw(INSTALL_SENT_KEY), "1")
  }

  func testForgetMeDeletesTheKeptInstall() async {
    let store = MemoryStore()
    let e = engine(store)
    _ = await withdrawnInstall(e)
    await e.forgetMe()
    XCTAssertNil(store.raw(INSTALL_DEFERRED_KEY))
  }

  /// A reset is a new install: the old one's id must not ride it.
  func testResetInstallDeletesTheKeptInstall() async {
    let store = MemoryStore()
    let e = engine(store)
    _ = await withdrawnInstall(e)
    await e.resetInstallState()
    XCTAssertNil(store.raw(INSTALL_DEFERRED_KEY))
  }

  /// A sandbox/production switch drops the queue and the install flag; the
  /// kept install belongs to the old environment too.
  func testAnEnvironmentChangeDeletesTheKeptInstall() {
    let store = MemoryStore()
    store.preload(ENVIRONMENT_KEY, "production")
    store.preload(INSTALL_DEFERRED_KEY, "{}")
    _ = reconcileEnvironment(.sandbox, store: store, scheduler: RecordingScheduler())
    XCTAssertNil(store.raw(INSTALL_DEFERRED_KEY))
  }
}

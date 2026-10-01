import Foundation
import XCTest

@testable import Advenue
@testable import AdvenueCore
@testable import AdvenuePlatform

/// Records every batch it is handed.
actor RecordingTransport: EventTransport {
  private(set) var seen: [[String]] = []
  func send(_ events: [ClientEvent]) async throws { seen.append(events.map(\.name)) }
}

/// Keeps whole events, not just names, so a seam test can assert the fields a
/// capability contributes.
actor RecordingEventTransport: EventTransport {
  private(set) var events: [ClientEvent] = []
  func send(_ batch: [ClientEvent]) async throws { events.append(contentsOf: batch) }
  func installEvent() -> ClientEvent? { events.first { $0.type == "install" } }
}

/// What the SDK told Apple. A named Sendable struct rather than a tuple: a
/// tuple array crossing an actor boundary crashed the test process outright,
/// which is a poor way to learn that the helper was the problem and not the SDK.
struct SkanCall: Sendable, Equatable {
  let fine: Int
  let coarse: CoarseValue
  let lock: Bool
}

/// Records what the SDK told Apple, and can be made to fail on demand.
actor RecordingSkanReporter: SkanReporter {
  private(set) var registered = 0
  private(set) var calls: [SkanCall] = []
  private var failNext: Bool

  init(failNext: Bool = false) { self.failNext = failNext }

  nonisolated func register() { Task { await self.noteRegistration() } }

  private func noteRegistration() { registered += 1 }

  func update(fine: Int, coarse: CoarseValue, lockWindow: Bool) async throws {
    if failNext {
      failNext = false
      throw IngestError(status: 500)
    }
    calls.append(SkanCall(fine: fine, coarse: coarse, lock: lockWindow))
  }
}

/// The test the component suites could not fail.
///
/// Every piece of the send path had its own passing test — `HttpTransport.send`,
/// `IngestError.isRetryable`, `backoffDelayMs`, `EventQueue.ack` — while nothing
/// in `Sources/` ever referenced `HttpTransport`. The SDK queued events into
/// UserDefaults and transmitted none of them, and 78 green tests reported it as
/// working. Unit coverage of every component says nothing about the seams
/// between them, so this asserts the seam directly: an event handed to the
/// public facade reaches a transport.
/// Collects onError contexts from whatever thread the SDK reports on.
final class ErrorContexts: @unchecked Sendable {
  private let lock = NSLock()
  private var contexts: [String] = []
  func add(_ context: String) { lock.lock(); contexts.append(context); lock.unlock() }
  var all: [String] { lock.lock(); defer { lock.unlock() }; return contexts }
}

final class SeamTests: XCTestCase {
  /// The install is once per installation, and the host test process shares one
  /// real UserDefaults suite across runs — so the first run writes the flag and
  /// every later run correctly refuses to fire a second install. That is the
  /// guard working, not a bug, but it makes the assertion depend on whether
  /// this machine has run the suite before. Clearing the flag makes the test
  /// assert the wiring rather than the history of the developer's laptop.
  override func setUp() {
    super.setUp()
    Self.clearPersistedState()
  }

  /// Clears the state a previous test could have left on this host.
  ///
  /// Called from tearDown as well as setUp, and that is the whole fix: the SKAN
  /// machine persists on the pipe's thread, so a write from the previous test
  /// could land AFTER the next test's setUp had already cleared. Clearing once
  /// the writer is stopped leaves nothing to race.
  private static func clearPersistedState() {
    let defaults = UserDefaults(suiteName: ADVENUE_SUITE)
    defaults?.removeObject(forKey: INSTALL_SENT_KEY)
    // Session state too: a case that backgrounds leaves a closed session behind,
    // and the next case's first foreground then reports the gap and emits a
    // session_end for it — a session boundary from the previous test.
    defaults?.removeObject(forKey: SESSION_STATE_KEY)
    // Every SKAN key, not just the state.
    //
    // The state is keyed by installation id, which is stable on this host, so a
    // value reported by an earlier run makes the next one correctly decide it
    // has nothing new to say — the same shape as the install flag above.
    //
    // `advenue.skan.config` is the one that actually bit: it caches the SERVED
    // conversion config, and a served config correctly wins over the one the
    // app supplied. So a fetch that landed during an earlier case replaced this
    // case's rules with the real app's, and the seam test read fine 0 for an
    // event no rule mentioned. It failed about two runs in three, only in a
    // full run, and only on a machine that could reach the network.
    for key in defaults?.dictionaryRepresentation().keys ?? [:].keys
    where key.hasPrefix("advenue.skan.") {
      defaults?.removeObject(forKey: key)
    }
  }

  /// Enrichment that settles at once, for every case that is not about
  /// enrichment. The default `.system()` sources ask AdServices for a token,
  /// which a test host never answers inside the 3 s install window — and since
  /// F-SDK-3 the install hold keeps every flush back until enrichment settles.
  /// So each such case paid the full window against its 5 s `until` budget,
  /// ran ~3.1 s when idle, and timed out under load.
  private static let settledSources = EnrichmentSources(
    searchAdsToken: { nil },
    advertisingId: { (idfa: nil, vendorId: nil) },
    appInstanceId: { nil })

  /// Every `FacadeState` a test builds, so tearDown can stop it.
  ///
  /// `Advenue.shutdown()` alone was not enough and the gap was invisible: it
  /// stops the STATIC facade, while each test here builds its own. A local
  /// state left running keeps its consumer task, its flush timer and its SKAN
  /// machine alive — and that machine writes to the same UserDefaults key,
  /// which is keyed by the host's stable installation id. So a previous test
  /// could persist SKAN state *after* the next test's setUp cleared it, and the
  /// next machine would then correctly decide it had nothing new to say. The
  /// seam test for SKAN failed about two runs in three, and only in a full run.
  private var states: [FacadeState] = []

  private func newState() -> FacadeState {
    let state = FacadeState()
    states.append(state)
    return state
  }

  override func tearDown() {
    // Each case builds its own FacadeState, and `Advenue.shutdown()` stops only
    // the static one — so without this every case leaks a consumer task and a
    // repeating flush timer for the rest of the run.
    for state in states { state.stop() }
    states = []
    Advenue.shutdown()
    Self.clearPersistedState()
    super.tearDown()
  }

  func testTrackedEventReachesTheTransport() async throws {
    let transport = RecordingTransport()
    let state = newState()
    state.start(AdvenueConfig(apiKey: "apk_live_x"), transport: transport, sources: Self.settledSources)

    // The invariant under test is the wiring, not the Keychain: an unsigned
    // simulator bundle cannot read it, and asserting an environment would make
    // this a test of the runner.
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.submit(.track(name: "purchase", properties: nil, type: "custom"))
    state.submit(.flush)

    try await Self.until(timeout: 5, state: state) { await !transport.seen.isEmpty }
    let seen = await transport.seen
    XCTAssertTrue(
      seen.flatMap { $0 }.contains("purchase"),
      "an event given to the facade never reached a transport")
  }

  /// The second seam. `SearchAdsTokenFetcher` had zero references in `Sources/`,
  /// `appInstanceIdProvider` was stored and never read, and no install event
  /// existed at all — every one of them individually tested. This asserts that
  /// an install reaches a transport carrying what the collector gathered.
  func testInstallReachesTheTransportEnriched() async throws {
    let transport = RecordingEventTransport()
    let state = newState()
    let sources = EnrichmentSources(
      searchAdsToken: { "tok-seam" },
      advertisingId: { (idfa: "IDFA-seam", vendorId: "VID-seam") },
      appInstanceId: { "aaaaaaaabbbbbbbbccccccccdddddddd" })

    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(config, transport: transport, sources: sources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    try await Self.until(timeout: 8, state: state) { await transport.installEvent() != nil }
    let install = await transport.installEvent()

    XCTAssertEqual(install?.adservicesToken, "tok-seam", "the Search Ads token never shipped")
    XCTAssertEqual(install?.idfa, "IDFA-seam", "the IDFA never shipped")
    XCTAssertEqual(install?.appInstanceId, "aaaaaaaabbbbbbbbccccccccdddddddd")
  }

  /// F-SDK-3, through the facade: enrichment that takes a while must not let
  /// the launch's own events reach the server ahead of the install. The app
  /// tracks and flushes right after initialize, exactly as the examples do.
  func testTheFirstBatchLeadsWithTheInstallWhileEnrichmentIsSlow() async throws {
    let transport = RecordingTransport()
    let state = newState()
    let sources = EnrichmentSources(
      searchAdsToken: {
        try? await Task.sleep(nanoseconds: 400_000_000)
        return nil
      },
      advertisingId: { (idfa: nil, vendorId: nil) },
      appInstanceId: { nil })

    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(config, transport: transport, sources: sources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.submit(.track(name: "purchase", properties: nil, type: "custom"))
    state.submit(.flush)

    try await Self.until(timeout: 8, state: state) {
      await transport.seen.flatMap { $0 }.contains("install")
    }
    let seen = await transport.seen
    XCTAssertEqual(seen.first?.first, "install", "a batch went out ahead of the install: \(seen)")
  }

  private func skanConfig() -> AdvenueConfig {
    var config = AdvenueConfig(
      apiKey: "apk_live_x",
      conversionValues: ConversionValueConfig(
        rules: [ConversionValueRule(fineValue: 10, events: ["signup"])]))
    config.flushIntervalMs = 0
    return config
  }

  /// The fourth seam. The SKAN model landed in AdvenueCore and nothing called
  /// it — the same shape as the transport nothing constructed, the install path
  /// nothing fired, and the Android device-info collector nothing called.
  func testATrackedEventReachesTheSkanReporter() async throws {
    let reporter = RecordingSkanReporter()
    let state = newState()
    state.start(skanConfig(), transport: RecordingTransport(), sources: Self.settledSources, skan: reporter)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.submit(.recordSkan(event: "signup", revenueMicros: nil, revenueCurrency: nil))

    // The signup call, not the first call.
    //
    // `start()` opens a session, and a session is an app event that legitimately
    // moves the conversion value: it matches no rule here, so it reports fine 0
    // before signup reports 10. Asserting on `calls.first` assumed the tracked
    // event was the only thing that could ever move the value, which made this
    // test fail about two runs in three depending on which call won the race.
    try await Self.until(timeout: 5) { await reporter.calls.contains { $0.fine == 10 } }
    let call = await reporter.calls.first { $0.fine == 10 }
    XCTAssertNotNil(call, "the tracked event never reached SKAdNetwork")
    XCTAssertEqual(call?.coarse, .low)
  }

  /// The fifth seam. The tracker decides correctly and the observers are
  /// registered — but nothing proved a signal actually reaches the session
  /// tracker, which is the same shape as the transport nothing constructed and
  /// the SKAN model nothing called.
  ///
  /// Backgrounding is asserted through the transport rather than the queue
  /// because it must do two things, and the second is the one that gets
  /// forgotten: close the session AND flush. A batch stranded at the moment the
  /// app leaves the foreground may otherwise not be sent for hours.
  func testABackgroundSignalClosesTheSessionAndFlushes() async throws {
    let transport = RecordingTransport()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(config, transport: transport, sources: Self.settledSources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.handle(.didEnterBackground)

    try await Self.until(timeout: 5) {
      await transport.seen.flatMap { $0 }.contains("session_end")
    }
  }

  /// An interruption is not a backgrounding. Control Center and an incoming
  /// call both resign active without backgrounding, and reading that as a
  /// session end inflates session counts by an order of magnitude.
  func testAnInterruptionEmitsNothing() async throws {
    let transport = RecordingTransport()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(config, transport: transport, sources: Self.settledSources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.handle(.willResignActive)
    state.handle(.didBecomeActive)
    state.submit(.flush)

    try await Self.until(timeout: 5) { await !transport.seen.isEmpty }
    let names = await transport.seen.flatMap { $0 }
    XCTAssertFalse(names.contains("session_end"), "an interruption must not end the session")
  }

  /// The public `notifyForeground()` goes through the same tracker as UIKit's
  /// own signals. Called while already foregrounded — an app that forwards
  /// `sceneDidBecomeActive` right after `initialize` — it used to reach the
  /// engine directly, which read the still-open session as a killed app and
  /// emitted a synthetic `session_end` plus a second `session_start`.
  func testAManualForegroundWhileForegroundedDoesNotSplitTheSession() async throws {
    let transport = RecordingTransport()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(config, transport: transport, sources: Self.settledSources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.notifyForeground()
    state.submit(.flush)

    try await Self.until(timeout: 5) { await !transport.seen.isEmpty }
    let names = await transport.seen.flatMap { $0 }
    // No start count: the persisted queue is shared across cases, so an earlier
    // case's unsent session_start can ride along. The split always shows up as
    // the synthetic session_end.
    XCTAssertFalse(names.contains("session_end"), "a repeated foreground must not end the session")
  }

  /// A launch into the background — background fetch, a silent push, a
  /// location relaunch — is not a session. `initialize` runs in
  /// didFinishLaunching either way, and it used to open a session and seed the
  /// tracker as foregrounded unconditionally: the phantom session carried the
  /// background launch's time, and since iOS posts no didEnterBackground for an
  /// app that never left it, the user's real open later was swallowed as a
  /// repeat. A backgrounding signal here must find no session to close.
  func testABackgroundLaunchOpensNoSession() async throws {
    let transport = RecordingTransport()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(config, transport: transport, sources: Self.settledSources, launchedInBackground: { true })
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.handle(.didEnterBackground)
    state.submit(.flush)

    try await Self.until(timeout: 5) { await !transport.seen.isEmpty }
    let names = await transport.seen.flatMap { $0 }
    XCTAssertFalse(names.contains("session_end"), "a background launch has no session to end")
  }

  /// `debug` is the integrator's window into an SDK that otherwise swallows
  /// every failure: it logs the start, each swallowed failure (everything
  /// `onError` sees) and each accepted batch.
  func testDebugLogsTheStartFailuresAndSentBatches() async throws {
    let transport = RecordingTransport()
    let sink = RecordingLogSink()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x", debug: true)
    config.flushIntervalMs = 0
    config.appVersion = "9.9.9"  // ignored, and reported through onError
    state.start(config, transport: transport, sources: Self.settledSources, logSink: sink)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.submit(.flush)
    try await Self.until(timeout: 5) { sink.lines.contains { $0.contains("sent") } }
    let lines = sink.lines
    XCTAssertTrue(lines.contains { $0.contains("initialized") }, "\(lines)")
    XCTAssertTrue(lines.contains { $0.contains("config.ignored:appVersion") }, "\(lines)")
  }

  /// A setup condition is reported as what it is, not as a transport error:
  /// `IngestError(status: 0)` printed as an HTTP failure that never happened
  /// and said nothing about the cause (a locked Keychain, an unsigned build).
  func testSetupConditionsAreReportedAsThemselves() async throws {
    let seen = ContextRecorder()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x", onError: { seen.add($0, $1) })
    config.flushIntervalMs = 0
    config.appVersion = "9.9.9"
    state.start(config, transport: RecordingTransport(), sources: Self.settledSources)

    let error = try XCTUnwrap(seen.errors["config.ignored:appVersion"])
    XCTAssertEqual(error as? AdvenueSetupError, .appVersionIgnored)
    XCTAssertTrue("\(AdvenueSetupError.identityDeferred)".contains("Keychain"))
    XCTAssertFalse("\(AdvenueSetupError.identityDeferred)".contains("status"))
  }

  /// Off by default, and silent: production apps get no log lines.
  func testDebugOffLogsNothing() async throws {
    let transport = RecordingTransport()
    let sink = RecordingLogSink()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    config.appVersion = "9.9.9"
    state.start(config, transport: transport, sources: Self.settledSources, logSink: sink)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.submit(.flush)
    try await Self.until(timeout: 5) { await !transport.seen.isEmpty }
    XCTAssertEqual(sink.lines, [])
  }

  /// A wrapper's version must reach the wire, not the native SDK's.
  ///
  /// An event stamped `0.1.0` says "the Swift SDK", which is true of every
  /// install and therefore useless. What support needs is which WRAPPER
  /// produced it, because a wrapper release pins the native snapshot inside it
  /// and wrapper-specific bugs are the ones that need identifying. Adjust and
  /// AppsFlyer both report the wrapper for this reason.
  func testAWrapperVersionOverridesTheNativeOne() async throws {
    let transport = RecordingEventTransport()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    config.sdkVersion = "react-native/0.9.0"
    state.start(config, transport: transport, sources: Self.settledSources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.submit(.track(name: "purchase", properties: nil, type: "custom"))
    state.submit(.flush)

    try await Self.until(timeout: 5) { await !transport.events.isEmpty }
    let event = await transport.events.first
    XCTAssertEqual(event?.sdkVersion, "react-native/0.9.0")
  }

  /// Left alone, it is still the native SDK's own version.
  func testTheNativeVersionIsTheDefault() async throws {
    let transport = RecordingEventTransport()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(config, transport: transport, sources: Self.settledSources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.submit(.track(name: "purchase", properties: nil, type: "custom"))
    state.submit(.flush)

    try await Self.until(timeout: 5) { await !transport.events.isEmpty }
    let event = await transport.events.first
    XCTAssertEqual(event?.sdkVersion, AdvenueVersion.current)
  }

  /// The app version is the SDK's to resolve, never the app's to supply.
  ///
  /// 1.0 shipped reading it only from the config, so apps that didn't pass one
  /// sent every event unversioned (2026-09-19). A config value is ignored and
  /// reported, not trusted. The bundle reader is injected: under XCTest
  /// `Bundle.main` is the test runner, not an app.
  func testTheAppVersionComesFromTheBundleAndAConfigValueIsIgnoredAndReported() async throws {
    let transport = RecordingEventTransport()
    let errors = ErrorContexts()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x", onError: { context, _ in errors.add(context) })
    config.flushIntervalMs = 0
    config.appVersion = "9.9.9"
    state.start(config, transport: transport, sources: Self.settledSources, appVersion: { "3.4.5" })
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.submit(.track(name: "purchase", properties: nil, type: "custom"))
    state.submit(.flush)

    try await Self.until(timeout: 5) { await !transport.events.isEmpty }
    let event = await transport.events.first
    XCTAssertEqual(event?.appVersion, "3.4.5")
    XCTAssertTrue(errors.all.contains("config.ignored:appVersion"))
  }

  func testNoConfigAppVersionMeansNothingIsReported() async throws {
    let transport = RecordingEventTransport()
    let errors = ErrorContexts()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x", onError: { context, _ in errors.add(context) })
    config.flushIntervalMs = 0
    state.start(config, transport: transport, sources: Self.settledSources, appVersion: { "3.4.5" })
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.submit(.track(name: "purchase", properties: nil, type: "custom"))
    state.submit(.flush)

    try await Self.until(timeout: 5) { await !transport.events.isEmpty }
    let event = await transport.events.first
    XCTAssertEqual(event?.appVersion, "3.4.5")
    XCTAssertFalse(errors.all.contains("config.ignored:appVersion"))
  }

  /// Apple wants registration at first launch; a late call loses the
  /// attribution window.
  func testRegistrationHappensAtStart() async throws {
    let reporter = RecordingSkanReporter()
    let state = newState()
    state.start(skanConfig(), transport: RecordingTransport(), sources: Self.settledSources, skan: reporter)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    try await Self.until(timeout: 5) { await reporter.registered > 0 }
  }

  /// A failed Apple call must not be confirmed: the device would refuse to send
  /// that value again and the window would report nothing for the rest of its
  /// life.
  func testAFailedUpdateIsRetriedOnTheNextEvent() async throws {
    let reporter = RecordingSkanReporter(failNext: true)
    let state = newState()
    state.start(skanConfig(), transport: RecordingTransport(), sources: Self.settledSources, skan: reporter)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.submit(.recordSkan(event: "signup", revenueMicros: nil, revenueCurrency: nil))
    // The first attempt throws and must leave the value unconfirmed.
    try await Task.sleep(nanoseconds: 300_000_000)
    state.submit(.recordSkan(event: "signup", revenueMicros: nil, revenueCurrency: nil))

    try await Self.until(timeout: 5) { await !reporter.calls.isEmpty }
    let call = await reporter.calls.first
    XCTAssertEqual(call?.fine, 10, "an unconfirmed value was never retried")
  }

  /// The fifth seam. Four capabilities in this SDK have been defined and joined
  /// to nothing; this asserts the attestation reaches the install rather than
  /// existing beside it.
  func testAttestationReachesTheInstallEvent() async throws {
    let transport = RecordingEventTransport()
    let state = newState()
    let sources = EnrichmentSources(
      searchAdsToken: { nil },
      advertisingId: { (idfa: nil, vendorId: nil) },
      appInstanceId: { nil },
      attestation: {
        (
          challenge: "challenge-seam",
          result: AttestationResult(keyId: "key-seam", attestationObject: "attest-seam")
        )
      })

    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(config, transport: transport, sources: sources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    try await Self.until(timeout: 8, state: state) { await transport.installEvent() != nil }
    let install = await transport.installEvent()

    XCTAssertEqual(install?.attestationToken, "attest-seam", "the attestation never shipped")
    XCTAssertEqual(install?.attestationType, "app-attest")
    XCTAssertEqual(install?.attestationKeyId, "key-seam")
    XCTAssertEqual(install?.attestationChallenge, "challenge-seam")
  }

  /// An install held for attestation is an install lost. Every failure path —
  /// unsupported device, challenge fetch, attestKey — must ship it anyway.
  func testAFailedAttestationStillShipsTheInstall() async throws {
    let transport = RecordingEventTransport()
    let state = newState()
    let sources = EnrichmentSources(
      searchAdsToken: { nil },
      advertisingId: { (idfa: nil, vendorId: nil) },
      appInstanceId: { nil },
      attestation: { nil })

    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(config, transport: transport, sources: sources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    try await Self.until(timeout: 8, state: state) { await transport.installEvent() != nil }
    let install = await transport.installEvent()
    XCTAssertNotNil(install, "the install must ship without attestation")
    XCTAssertNil(install?.attestationToken)
  }

  /// Meta AEM: a link from Meta carries an opaque campaign_ids blob. Emitted at
  /// most once per URL — the same link re-opened is not a second measurement,
  /// and the server dedups on the same hash.
  func testAMetaLinkEmitsOneAemEventAndOnlyOne() async throws {
    let transport = RecordingEventTransport()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(config, transport: transport, sources: Self.settledSources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    var components = URLComponents(string: "https://go.advenue.io/x")!
    components.queryItems = [
      URLQueryItem(name: "al_applink_data", value: #"{"campaign_ids":"blob-seam"}"#)
    ]
    let link = components.url!

    state.deepLink(link)
    state.deepLink(link)

    try await Self.until(timeout: 5, state: state) {
      await transport.events.contains { $0.name == "adv_meta_aem" }
    }

    let events = await transport.events
    let aem = events.filter { $0.name == "adv_meta_aem" }
    XCTAssertEqual(aem.count, 1, "the same link re-opened is not a second measurement")
    XCTAssertEqual(aem.first?.properties?["campaignIds"], .string("blob-seam"))
    XCTAssertNotNil(aem.first?.properties?["sourceUrlHash"])
  }

  /// Polls, re-flushing each round. A flush submitted while one is already in
  /// flight is a no-op by design — the re-entrancy guard — so a single Flush is
  /// not enough to drain a queue that grew while the first request was out. In
  /// a shipping app the 15-second timer covers this.
  private static func until(
    timeout: TimeInterval, state: FacadeState? = nil,
    _ condition: @Sendable () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      state?.submit(.flush)
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("condition never became true within \(timeout)s")
  }
}

/// Collects debug log lines.
final class RecordingLogSink: AdvenueLogSink, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  var lines: [String] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
  func log(_ message: String) {
    lock.lock()
    stored.append(message)
    lock.unlock()
  }
}

/// Collects what `onError` receives, by context.
final class ContextRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String: any Error] = [:]
  var errors: [String: any Error] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
  func add(_ context: String, _ error: any Error) {
    lock.lock()
    stored[context] = error
    lock.unlock()
  }
}

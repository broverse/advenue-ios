import Foundation
import XCTest

@testable import Advenue
@testable import AdvenueCore
@testable import AdvenuePlatform

/// Counts how often an attestation source was asked.
actor AttestationCounter {
  private(set) var count = 0
  func hit() { count += 1 }
}

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

/// Holds the FIRST reset call at the "server" until the test releases it, so
/// a test can act while `resetInstall` is suspended on the network. Later
/// calls pass straight through: a reset that should have been refused then
/// shows up as a second call instead of hanging the suite.
actor GatedDeviceReset: SandboxDeviceResetting {
  private(set) var calls = 0
  private var released = false
  private var waiter: CheckedContinuation<Void, Never>?
  func reset(deviceId: String, installationId: String?) async throws {
    calls += 1
    if released || calls > 1 { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
}

/// Holds the FIRST send until the test releases it, so the pipe is stuck in a
/// flush: a `resetInstall` taken then waits in its drain (the slow-flush case).
actor GatedTransport: EventTransport {
  private(set) var sends = 0
  private var released = false
  private var waiter: CheckedContinuation<Void, Never>?
  func send(_ events: [ClientEvent]) async throws {
    sends += 1
    if released || sends > 1 { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
}

/// GatedTransport that also keeps every batch it was handed, the held one
/// included, so a test can say what was sent after the gate.
actor GatedRecordingTransport: EventTransport {
  private(set) var batches: [[ClientEvent]] = []
  private var released = false
  private var waiter: CheckedContinuation<Void, Never>?
  var sends: Int { batches.count }
  var events: [ClientEvent] { batches.flatMap { $0 } }
  func send(_ events: [ClientEvent]) async throws {
    batches.append(events)
    if released || batches.count > 1 { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
}

/// An in-memory secure store whose reads can be made to fail the way a locked
/// Keychain does, so a test can defer identity on demand.
final class ScriptedSecureStore: SecureStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: String] = [:]
  private var unreadable = false
  func makeUnreadable() {
    lock.lock()
    unreadable = true
    lock.unlock()
  }
  func value(_ key: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return values[key]
  }
  func read(_ key: String) -> SecureReadResult {
    lock.lock()
    defer { lock.unlock() }
    if unreadable { return .unavailable }
    return values[key].map { .found($0) } ?? .absent
  }
  func write(_ value: String, forKey key: String) {
    lock.lock()
    values[key] = value
    lock.unlock()
  }
  func delete(_ key: String) {
    lock.lock()
    values.removeValue(forKey: key)
    lock.unlock()
  }
}

/// Parks the first line it is given until `proceed` is signalled, so a test can
/// hold a `start` part-way (after it took over the reset buffer, before it
/// resolves identity). Later lines pass straight through.
final class ParkingSink: AdvenueLogSink, @unchecked Sendable {
  private let lock = NSLock()
  private var seen = false
  private var parkedNow = false
  let proceed = DispatchSemaphore(value: 0)
  var parked: Bool {
    lock.lock()
    defer { lock.unlock() }
    return parkedNow
  }
  func log(_ message: String) {
    lock.lock()
    let first = !seen
    seen = true
    if first { parkedNow = true }
    lock.unlock()
    if first { proceed.wait() }
  }
}

/// Calls `body` on the first line it is given, then just records.
final class HookSink: AdvenueLogSink, @unchecked Sendable {
  private let lock = NSLock()
  private var hook: (() -> Void)?
  func arm(_ body: @escaping () -> Void) {
    lock.lock()
    hook = body
    lock.unlock()
  }
  func log(_ message: String) {
    lock.lock()
    let body = hook
    hook = nil
    lock.unlock()
    body?()
  }
}

/// Every pipe a FacadeState built.
final class PipeLog: @unchecked Sendable {
  private let lock = NSLock()
  private var pipes: [CommandPipe] = []
  func add(_ pipe: CommandPipe) { lock.lock(); pipes.append(pipe); lock.unlock() }
  var all: [CommandPipe] { lock.lock(); defer { lock.unlock() }; return pipes }
}

/// Reset tasks started from many threads.
final class TaskLog: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [Task<String?, Never>] = []
  func add(_ task: Task<String?, Never>) { lock.lock(); tasks.append(task); lock.unlock() }
  func drain() -> [Task<String?, Never>] {
    lock.lock()
    defer { lock.unlock() }
    let out = tasks
    tasks = []
    return out
  }
}

/// A failure whose text carries an identifier, as a careless error might.
struct LeakyError: Error, CustomStringConvertible {
  var description: String { "device 11111111-2222-3333-4444-555555555555 refused" }
}

/// Answers the deferred-deep-link lookup at once, and remembers who asked.
final class StubConversionFetcher: ConversionFetcher, @unchecked Sendable {
  let result: ConversionResult
  init(_ result: ConversionResult) { self.result = result }
  func fetch() async throws -> ConversionResult { result }
}

/// Records what resetInstall asked the server to clear; can answer like an old server.
actor RecordingDeviceReset: SandboxDeviceResetting {
  struct Call: Sendable, Equatable {
    let deviceId: String
    let installationId: String?
  }
  private(set) var calls: [Call] = []
  private let status: Int?
  init(failingWith status: Int? = nil) { self.status = status }
  func reset(deviceId: String, installationId: String?) async throws {
    calls.append(Call(deviceId: deviceId, installationId: installationId))
    if let status { throw IngestError(status: status) }
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
    defaults?.removeObject(forKey: ENVIRONMENT_KEY)
    // Consent and the user id: the consent cases persist a decision that would
    // otherwise open (or close) the gate for the next case.
    defaults?.removeObject(forKey: CONSENT_KEY)
    defaults?.removeObject(forKey: CONSENT_DATA_KEY)
    defaults?.removeObject(forKey: USER_ID_KEY)
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
    // Pinned to what the sources report: in production both readers see one
    // system, and `until`'s flushes refresh between the install task's
    // submits — a default (nil) source here would let a poll land between
    // setIdentity and trackInstall and stamp the install IDFA-less.
    state.start(
      config, transport: transport, sources: sources,
      advertisingSource: {
        AdvertisingSnapshot(idfa: "IDFA-seam", vendorId: "VID-seam", limitAdTracking: false)
      })
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    try await Self.until(timeout: 8, state: state) { await transport.installEvent() != nil }
    let install = await transport.installEvent()

    XCTAssertEqual(install?.adservicesToken, "tok-seam", "the Search Ads token never shipped")
    XCTAssertEqual(install?.idfa, "IDFA-seam", "the IDFA never shipped")
    XCTAssertEqual(install?.appInstanceId, "aaaaaaaabbbbbbbbccccccccdddddddd")
  }

  /// D11 through the facade: a flush picks up the CURRENT advertising
  /// identity, not the one install enrichment saw. The init sources report no
  /// IDFA (ATT unresolved at initialize); the refresh source reports the
  /// granted one. If the refresh never ran, the probe would ship IDFA-less.
  func testFlushRefreshPicksUpTheCurrentAdvertisingIdentity() async throws {
    let transport = RecordingEventTransport()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(
      config, transport: transport, sources: Self.settledSources,
      advertisingSource: {
        AdvertisingSnapshot(idfa: "IDFA-refresh", vendorId: "VID-refresh", limitAdTracking: false)
      })
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    // Let the install task finish first: its setIdentity(nil) must land before
    // the refresh, or the test races the wiring instead of asserting it. Once
    // the install reached the transport, the task's only remaining submit is
    // its final flush, which writes no identity.
    try await Self.until(timeout: 8, state: state) { await transport.installEvent() != nil }

    state.submit(.track(name: "probe", properties: nil, type: "custom"))
    state.submit(.flush)
    try await Self.until(timeout: 5, state: state) {
      await transport.events.contains { $0.name == "probe" }
    }
    let probe = await transport.events.first { $0.name == "probe" }
    XCTAssertEqual(
      probe?.idfa, "IDFA-refresh",
      "the flush must refresh the identity from the current system values")
    XCTAssertEqual(probe?.vendorId, "VID-refresh")
  }

  /// Task 15 through the facade: the flush refresh carries the CURRENT ATT
  /// status onto the events that follow, and every event carries the
  /// installation id. A user who revoked tracking in Settings must not keep
  /// shipping "authorized".
  func testFlushRefreshStampsTheCurrentAttStatusAndTheInstallationId() async throws {
    let transport = RecordingEventTransport()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(
      config, transport: transport, sources: Self.settledSources,
      advertisingSource: {
        AdvertisingSnapshot(
          idfa: nil, vendorId: "VID-refresh", limitAdTracking: true, attStatus: .denied)
      })
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    try await Self.until(timeout: 8, state: state) { await transport.installEvent() != nil }

    state.submit(.track(name: "probe", properties: nil, type: "custom"))
    state.submit(.flush)
    try await Self.until(timeout: 5, state: state) {
      await transport.events.contains { $0.name == "probe" }
    }
    let probe = await transport.events.first { $0.name == "probe" }
    XCTAssertEqual(probe?.attStatus, "denied")
    XCTAssertEqual(probe?.limitAdTracking, true)
    let events = await transport.events
    for event in events {
      XCTAssertNotNil(event.installationId, "\(event.name) shipped without the installation id")
      XCTAssertNotNil(event.attStatus, "\(event.name) shipped without the ATT status")
    }
  }

  /// The refresh reads the vendor id only on the main thread — off it (the
  /// flush timer, React Native's JS thread) it reports nil rather than block
  /// on `main.sync`. That nil must not clear the id install enrichment read.
  func testOffMainRefreshKeepsTheEnrichedVendorId() async throws {
    let transport = RecordingEventTransport()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(
      config, transport: transport,
      sources: EnrichmentSources(
        searchAdsToken: { nil },
        advertisingId: { (idfa: nil, vendorId: "VID-enriched") },
        appInstanceId: { nil }),
      advertisingSource: {
        AdvertisingSnapshot(idfa: "IDFA-refresh", vendorId: nil, limitAdTracking: false)
      })
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    try await Self.until(timeout: 8, state: state) { await transport.installEvent() != nil }

    state.submit(.track(name: "probe", properties: nil, type: "custom"))
    state.submit(.flush)
    try await Self.until(timeout: 5, state: state) {
      await transport.events.contains { $0.name == "probe" }
    }
    let probe = await transport.events.first { $0.name == "probe" }
    XCTAssertEqual(probe?.idfa, "IDFA-refresh")
    XCTAssertEqual(probe?.vendorId, "VID-enriched", "an unread vendor id must not clear the known one")
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

  /// Spec 2 §7.2: the sandbox warning is logged even with debug off.
  func testSandboxLogsItsWarningWithoutDebug() async throws {
    let sink = RecordingLogSink()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x", environment: .sandbox)
    config.flushIntervalMs = 0
    state.start(config, transport: RecordingTransport(), sources: Self.settledSources, logSink: sink)
    XCTAssertTrue(sink.lines.contains(SANDBOX_WARNING), "\(sink.lines)")
  }

  /// Production stays silent, as before.
  func testProductionLogsNoSandboxWarning() async throws {
    let sink = RecordingLogSink()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(config, transport: RecordingTransport(), sources: Self.settledSources, logSink: sink)
    XCTAssertFalse(sink.lines.contains(SANDBOX_WARNING))
  }

  /// The "environment changed" line is a debug aid: silent with debug off.
  func testEnvironmentChangeNoticeIsDebugGated() {
    let off = RecordingLogSink()
    let (_, silent) = withDebugLogging(
      AdvenueConfig(apiKey: "apk_live_x", environment: .sandbox), sink: off)
    logEnvironmentChange(dropped: 3, to: .sandbox, log: silent)
    XCTAssertTrue(off.lines.isEmpty, "\(off.lines)")

    let on = RecordingLogSink()
    let (_, loud) = withDebugLogging(
      AdvenueConfig(apiKey: "apk_live_x", debug: true, environment: .sandbox), sink: on)
    logEnvironmentChange(dropped: 3, to: .sandbox, log: loud)
    XCTAssertTrue(
      on.lines.contains { $0.contains("environment changed to sandbox") && $0.contains("3") },
      "\(on.lines)")
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

  /// F7 (spec D7): the attestation's challenge fetch carries the device id, so
  /// under requireConsent it must not run before consent. Once consent is
  /// granted it runs once, and the deferred install it releases carries it.
  func testAttestationWaitsForConsentAndRidesTheReleasedInstall() async throws {
    let transport = RecordingEventTransport()
    let state = newState()
    let calls = AttestationCounter()
    let sources = EnrichmentSources(
      searchAdsToken: { nil },
      advertisingId: { (idfa: nil, vendorId: nil) },
      appInstanceId: { nil },
      attestation: {
        await calls.hit()
        return (
          challenge: "challenge-consent",
          result: AttestationResult(keyId: "key-consent", attestationObject: "attest-consent")
        )
      })

    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    config.requireConsent = true
    state.start(config, transport: transport, sources: sources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    // The install flow with settled sources finishes well inside this.
    try await Task.sleep(nanoseconds: 500_000_000)
    state.submit(.flush)
    try await Task.sleep(nanoseconds: 200_000_000)
    let before = await calls.count
    XCTAssertEqual(before, 0, "attestation ran (and fetched a challenge) before consent")
    let earlyInstall = await transport.installEvent()
    XCTAssertNil(earlyInstall, "no install may leave before consent")

    state.rememberConsent(true)
    state.submit(.setConsent(true))

    try await Self.until(timeout: 8, state: state) { await transport.installEvent() != nil }
    let install = await transport.installEvent()
    let after = await calls.count
    XCTAssertEqual(after, 1, "attestation must run exactly once, after consent")
    XCTAssertEqual(install?.attestationToken, "attest-consent", "the released install lost its attestation")
    XCTAssertEqual(install?.attestationKeyId, "key-consent")
    XCTAssertEqual(install?.attestationChallenge, "challenge-consent")
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

  /// M2 travels the whole seam: the public config's switch must reach the
  /// engine that scrubs. The field was missing from AdvenueConfig entirely —
  /// iOS scrubbed always, with no opt-out — while Android exposed it.
  func testPiiScrubDefaultsOnThroughTheFacade() async throws {
    let transport = RecordingEventTransport()
    let state = newState()
    state.start(
      AdvenueConfig(apiKey: "apk_live_x"), transport: transport, sources: Self.settledSources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.submit(.track(name: "scrubbed", properties: ["email": .string("a@b.com")], type: "custom"))
    try await Self.until(timeout: 5, state: state) {
      await transport.events.contains { $0.name == "scrubbed" }
    }
    let event = await transport.events.first { $0.name == "scrubbed" }
    XCTAssertNil(event?.properties?["email"], "the default config must scrub PII before send")
  }

  func testPiiScrubOptOutTravelsThroughTheFacade() async throws {
    let transport = RecordingEventTransport()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.piiScrubEnabled = false
    state.start(config, transport: transport, sources: Self.settledSources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    state.submit(.track(name: "unscrubbed", properties: ["email": .string("a@b.com")], type: "custom"))
    try await Self.until(timeout: 5, state: state) {
      await transport.events.contains { $0.name == "unscrubbed" }
    }
    let event = await transport.events.first { $0.name == "unscrubbed" }
    XCTAssertEqual(
      event?.properties?["email"], .string("a@b.com"),
      "an explicit opt-out must leave properties untouched")
  }

  // MARK: resetInstall (spec 3 §7)

  func testResetInstallIsANoOpInProduction() async throws {
    let sink = RecordingLogSink()
    let recorder = RecordingDeviceReset()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(
      config, transport: RecordingTransport(), sources: Self.settledSources, logSink: sink,
      deviceReset: recorder)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    let before = state.currentDeviceId
    let result = await state.resetInstall()
    XCTAssertNil(result)
    XCTAssertEqual(state.currentDeviceId, before)
    XCTAssertTrue(
      sink.lines.contains("Advenue: resetInstall() works only in sandbox."), "\(sink.lines)")
    let calls = await recorder.calls
    XCTAssertTrue(calls.isEmpty)
  }

  func testResetInstallInSandboxRotatesTheDeviceAndSendsANewInstall() async throws {
    let transport = RecordingEventTransport()
    let recorder = RecordingDeviceReset()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x", environment: .sandbox)
    config.flushIntervalMs = 0
    state.start(config, transport: transport, sources: Self.settledSources, deviceReset: recorder)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    let old = try XCTUnwrap(state.currentDeviceId)
    let oldInstallation = UserDefaults(suiteName: ADVENUE_SUITE)?.string(
      forKey: INSTALLATION_ID_KEY)
    // Queued but never flushed: must not survive the reset.
    state.submit(.track(name: "before_reset", properties: nil, type: "custom"))

    let new = await state.resetInstall()
    XCTAssertNotNil(new)
    XCTAssertNotEqual(new, old)
    let calls = await recorder.calls
    XCTAssertEqual(
      calls, [RecordingDeviceReset.Call(deviceId: old, installationId: oldInstallation)])

    state.submit(.flush)
    try await Self.until(timeout: 5, state: state) {
      await transport.events.contains { $0.type == "install" && $0.deviceId == new }
    }
    let names = await transport.events.map(\.name)
    XCTAssertFalse(names.contains("before_reset"), "\(names)")
  }

  func testResetInstallContinuesWhenTheServerIsOld() async throws {
    let sink = RecordingLogSink()
    let recorder = RecordingDeviceReset(failingWith: 404)
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x", environment: .sandbox)
    config.flushIntervalMs = 0
    state.start(
      config, transport: RecordingTransport(), sources: Self.settledSources, logSink: sink,
      deviceReset: recorder)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    let old = state.currentDeviceId
    let new = await state.resetInstall()
    XCTAssertNotNil(new)
    XCTAssertNotEqual(new, old)
    // The 404 is said, not swallowed.
    XCTAssertTrue(
      sink.lines.contains { $0.contains("resetInstall()") && $0.contains("404") },
      "\(sink.lines)")
  }

  /// PF29: the native SDK persists no conversion data (the server's `sbx:conv`
  /// is the only cache, and the endpoint deletes it), so the local reset is
  /// exactly: install flag, installation id, queue and session go; consent, the
  /// user id and the environment stay.
  func testResetInstallClearsTheInstallButKeepsConsentUserAndEnvironment() async throws {
    // Sendable, unlike UserDefaults, so the polling closure can read it.
    let defaults = UserDefaultsStore()
    let files = try XCTUnwrap(CacheFileStore.caches())
    let store = CompositeStore(files: files)
    defer {
      defaults.removeObject(forKey: CONSENT_KEY)
      defaults.removeObject(forKey: USER_ID_KEY)
      store.removeObject(forKey: QUEUE_KEY)
    }
    // This device already sent its install, so the first launch owes nothing.
    // The environment is seeded too: a changed one would itself clear the flag.
    defaults.set(AdvenueEnvironment.sandbox.rawValue, forKey: ENVIRONMENT_KEY)
    defaults.set("1", forKey: INSTALL_SENT_KEY)
    // The new install's enrichment is held back, so nothing re-writes the keys
    // between the reset and the assertions below.
    let slowSources = EnrichmentSources(
      searchAdsToken: {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return nil
      },
      advertisingId: { (idfa: nil, vendorId: nil) },
      appInstanceId: { nil })
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x", environment: .sandbox)
    config.flushIntervalMs = 0
    state.start(
      config, transport: RecordingTransport(), sources: slowSources,
      launchedInBackground: { true }, deviceReset: RecordingDeviceReset())
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    let oldInstallation = try XCTUnwrap(defaults.string(forKey: INSTALLATION_ID_KEY))

    state.submit(.setConsent(true))
    state.submit(.setUserId("user-1"))
    state.notifyForeground()
    state.submit(.track(name: "queued", properties: nil, type: "custom"))
    // No flush: the queue must still be on disk when the reset runs.
    try await Self.until(timeout: 5) {
      defaults.string(forKey: SESSION_STATE_KEY) != nil
        && defaults.string(forKey: USER_ID_KEY) == "user-1"
        && store.string(forKey: QUEUE_KEY) != nil
    }

    XCTAssertEqual(defaults.string(forKey: INSTALL_SENT_KEY), "1", "precondition")
    // The one on-device conversion value: SKAN's per-installation state. Keyed
    // by the old installation id, so the new install would never read it; the
    // reset still removes it rather than leave an orphan behind.
    let oldSkanState = skanStateKey(installationId: oldInstallation)
    defaults.set("{}", forKey: oldSkanState)

    _ = await state.resetInstall()

    XCTAssertNil(defaults.string(forKey: oldSkanState), "skan state")
    XCTAssertNil(defaults.string(forKey: INSTALL_SENT_KEY), "install_sent")
    XCTAssertNotEqual(
      defaults.string(forKey: INSTALLATION_ID_KEY), oldInstallation, "installation_id")
    XCTAssertNil(store.string(forKey: QUEUE_KEY), "queue")
    XCTAssertNil(defaults.string(forKey: SESSION_STATE_KEY), "session")
    XCTAssertEqual(defaults.string(forKey: CONSENT_KEY), "granted", "consent")
    XCTAssertEqual(defaults.string(forKey: USER_ID_KEY), "user-1", "user_id")
    XCTAssertEqual(defaults.string(forKey: ENVIRONMENT_KEY), "sandbox", "environment")
  }

  // MARK: resetInstall races (fix round 1, I1/M2)

  private func startGatedSandbox(
    _ state: FacadeState, gate: GatedDeviceReset, transport: (any EventTransport)? = nil,
    sink: RecordingLogSink? = nil, secure: (any SecureStore)? = nil
  ) {
    var config = AdvenueConfig(apiKey: "apk_live_x", environment: .sandbox)
    config.flushIntervalMs = 0
    state.start(
      config, transport: transport ?? RecordingTransport(), sources: Self.settledSources,
      logSink: sink, deviceReset: gate, secureStore: secure)
  }

  /// Starts a sandbox SDK whose first send the transport holds, then begins a
  /// reset: on return the pipe is detached and the drain waits behind that
  /// send until `transport.release()`.
  private func startResetInTheDrain(
    _ state: FacadeState, transport: GatedRecordingTransport, sink: RecordingLogSink? = nil,
    secure: (any SecureStore)? = nil
  ) async throws -> Task<String?, Never> {
    let gate = GatedDeviceReset()
    await gate.release()
    startGatedSandbox(state, gate: gate, transport: transport, sink: sink, secure: secure)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    state.submit(.track(name: "before_reset", properties: nil, type: "custom"))
    try await Self.until(timeout: 5, state: state) { await transport.sends == 1 }
    let reset = Task { await state.resetInstall() }
    try await Self.until(timeout: 5) { !state.isRunning }
    return reset
  }

  /// K1: forgetMe while the reset drains. The erasure cannot go onto a pipe,
  /// so the reset performs it: the device id, installation id, consent and
  /// user id are all gone, nothing restarts, and no install is sent after.
  func testForgetMeDuringTheDrainErasesEverythingAndSendsNoInstall() async throws {
    let transport = GatedRecordingTransport()
    let state = newState()
    let gate = GatedDeviceReset()
    await gate.release()
    startGatedSandbox(state, gate: gate, transport: transport)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    state.rememberConsent(true)
    state.submit(.setConsent(true))
    state.submit(.setUserId("user-1"))
    state.submit(.track(name: "before_reset", properties: nil, type: "custom"))
    try await Self.until(timeout: 5, state: state) { await transport.sends == 1 }
    let reset = Task { await state.resetInstall() }
    try await Self.until(timeout: 5) { !state.isRunning }

    // Buffered for the next pipe, then erased with everything else.
    state.submit(.setUserId("user-2"))
    state.forgetMe()
    await transport.release()
    let result = await reset.value

    XCTAssertNil(result, "the reset restarted an erased SDK")
    XCTAssertFalse(state.isRunning)
    let defaults = UserDefaultsStore()
    XCTAssertNil(defaults.string(forKey: CONSENT_KEY), "consent")
    XCTAssertNil(defaults.string(forKey: USER_ID_KEY), "user_id")
    XCTAssertNil(defaults.string(forKey: INSTALLATION_ID_KEY), "installation_id")
    XCTAssertNil(defaults.string(forKey: INSTALL_SENT_KEY), "install_sent")
    XCTAssertEqual(KeychainStore().read(DEVICE_ID_KEY), .absent, "device_id")
    XCTAssertFalse(state.trackingConsent)
    try await Task.sleep(nanoseconds: 300_000_000)
    let later = await transport.batches.dropFirst().flatMap { $0 }
    XCTAssertFalse(later.contains { $0.type == "install" }, "an install was sent after forgetMe")
  }

  /// K2: the drain keeps one of each setting, in the order of the last write.
  func testTheDrainKeepsOnlyTheLastOfEachSetting() async throws {
    let transport = GatedRecordingTransport()
    let state = newState()
    defer {
      let defaults = UserDefaultsStore()
      defaults.removeObject(forKey: CONSENT_KEY)
      defaults.removeObject(forKey: CONSENT_DATA_KEY)
      defaults.removeObject(forKey: USER_ID_KEY)
    }
    let reset = try await startResetInTheDrain(state, transport: transport)

    state.submit(.setUserId("u1"))
    state.submit(.setConsent(true))
    state.submit(.setUserId("u2"))
    state.submit(.setConsentData(Consent(isUserSubjectToGDPR: true)))
    state.submit(.setConsent(false))
    for index in 0..<50 { state.submit(.setUserId("bulk-\(index)")) }
    state.submit(.setUserId("u3"))
    XCTAssertEqual(state.resetBufferKinds, ["setConsentData", "setConsent", "setUserId"])

    await transport.release()
    let result = await reset.value
    _ = try XCTUnwrap(result)
    try await Self.until(timeout: 5) {
      let defaults = UserDefaultsStore()
      return defaults.string(forKey: CONSENT_KEY) == "denied"
        && defaults.string(forKey: USER_ID_KEY) == "u3"
        && defaults.string(forKey: CONSENT_DATA_KEY) != nil
    }
  }

  /// K3: the restart defers identity, so no pipe takes what the drain
  /// buffered. It goes to the store instead, where the next start loads it.
  func testWhatTheDrainBufferedReachesTheStoreWhenTheRestartDefers() async throws {
    let transport = GatedRecordingTransport()
    let secure = ScriptedSecureStore()
    let state = newState()
    defer {
      let defaults = UserDefaultsStore()
      defaults.removeObject(forKey: CONSENT_KEY)
      defaults.removeObject(forKey: USER_ID_KEY)
    }
    state.submit(.setConsent(true))
    let reset = try await startResetInTheDrain(state, transport: transport, secure: secure)

    state.submit(.setConsent(false))
    state.submit(.setUserId("user-k3"))
    secure.makeUnreadable()
    await transport.release()
    _ = await reset.value

    XCTAssertFalse(state.isRunning, "precondition: the restart deferred")
    let defaults = UserDefaultsStore()
    XCTAssertEqual(defaults.string(forKey: CONSENT_KEY), "denied")
    XCTAssertEqual(defaults.string(forKey: USER_ID_KEY), "user-k3")
  }

  /// K4: a re-initialize during the drain owns the store from then on. The old
  /// engine's reset still runs when the drain reaches it, but must not wipe the
  /// new instance's install flag.
  func testReinitializeDuringTheDrainKeepsTheNewInstancesStore() async throws {
    let transport = GatedRecordingTransport()
    let state = newState()
    let reset = try await startResetInTheDrain(state, transport: transport)
    XCTAssertEqual(UserDefaultsStore().string(forKey: INSTALL_SENT_KEY), "1", "precondition")

    let gate = GatedDeviceReset()
    await gate.release()
    startGatedSandbox(state, gate: gate)
    await transport.release()
    let result = await reset.value

    XCTAssertNil(result)
    XCTAssertTrue(state.isRunning, "the re-initialized SDK was torn down")
    XCTAssertEqual(
      UserDefaultsStore().string(forKey: INSTALL_SENT_KEY), "1",
      "the old engine's reset wiped the new instance's install flag")
  }

  /// K5: the restart claims the SDK under the same lock that starts it. A
  /// restart whose generation has moved (a stop got in first) changes nothing:
  /// the SDK stays stopped and the identity is not rotated.
  func testARestartWhoseGenerationMovedDoesNotRevive() async throws {
    let secure = ScriptedSecureStore()
    let state = newState()
    let gate = GatedDeviceReset()
    startGatedSandbox(state, gate: gate, secure: secure)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    let old = secure.value(DEVICE_ID_KEY)
    state.stop()

    var config = AdvenueConfig(apiKey: "apk_live_x", environment: .sandbox)
    config.flushIntervalMs = 0
    let claimed = state.start(
      config, transport: RecordingTransport(), sources: Self.settledSources,
      deviceReset: gate, secureStore: secure,
      resetPlan: ResetPlan(expected: -1, mintedDeviceId: "minted"))

    XCTAssertFalse(claimed)
    XCTAssertFalse(state.isRunning, "a stopped SDK was revived")
    XCTAssertEqual(secure.value(DEVICE_ID_KEY), old, "the identity rotated anyway")
  }

  /// K7: a deep link that arrives while the reset drains is not dropped; the
  /// restart replays it, so it belongs to the new install.
  func testADeepLinkDuringTheDrainReachesTheNewInstall() async throws {
    let transport = GatedRecordingTransport()
    let state = newState()
    let reset = try await startResetInTheDrain(state, transport: transport)

    state.deepLink(try XCTUnwrap(URL(string: "https://example.com/promo")))
    XCTAssertEqual(state.bufferedDeepLinkCount, 1)
    await transport.release()
    let result = await reset.value
    let new = try XCTUnwrap(result)

    try await Self.until(timeout: 5, state: state) {
      await transport.events.contains { $0.name == "deep_link" && $0.deviceId == new }
    }
    XCTAssertEqual(state.bufferedDeepLinkCount, 0)
  }

  /// Starts a sandbox SDK on `transport`, then sends a sentinel and waits for
  /// it: anything the start replayed is queued ahead of it, so once the
  /// sentinel is seen, a replayed deep link would have been seen too.
  private func startAndAwaitSentinel(
    _ state: FacadeState, transport: RecordingEventTransport
  ) async throws {
    let gate = GatedDeviceReset()
    await gate.release()
    startGatedSandbox(state, gate: gate, transport: transport)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    state.submit(.track(name: "fm1_sentinel", properties: nil, type: "custom"))
    state.submit(.flush)
    try await Self.until(timeout: 5, state: state) {
      await transport.events.contains { $0.name == "fm1_sentinel" }
    }
  }

  /// FM1: a link buffered while the reset drains belongs to the identity that
  /// forgetMe erases. It is dropped with everything else, not replayed under
  /// the next identity.
  func testALinkBufferedInTheDrainDoesNotSurviveForgetMe() async throws {
    let transport = GatedRecordingTransport()
    let state = newState()
    let reset = try await startResetInTheDrain(state, transport: transport)
    state.deepLink(try XCTUnwrap(URL(string: "https://example.com/before-erasure")))
    XCTAssertEqual(state.bufferedDeepLinkCount, 1, "precondition: buffered by the drain")

    state.forgetMe()
    let newTransport = RecordingEventTransport()
    try await startAndAwaitSentinel(state, transport: newTransport)
    await transport.release()
    _ = await reset.value

    let sent = await newTransport.events + transport.events
    XCTAssertFalse(
      sent.contains { $0.name == "deep_link" }, "a link from before the erasure was sent")
    XCTAssertEqual(state.bufferedDeepLinkCount, 0)
  }

  /// FM1: after forgetMe and until the next initialize, a deep link is
  /// dropped, as the erased engine dropped it: it is neither buffered nor
  /// replayed under the next identity.
  func testADeepLinkAfterForgetMeIsDropped() async throws {
    let state = newState()
    let first = RecordingEventTransport()
    try await startAndAwaitSentinel(state, transport: first)
    state.forgetMe()

    state.deepLink(try XCTUnwrap(URL(string: "https://example.com/after-erasure")))
    let next = RecordingEventTransport()
    try await startAndAwaitSentinel(state, transport: next)

    let sent = await first.events + next.events
    XCTAssertFalse(sent.contains { $0.name == "deep_link" }, "an erased SDK sent a link")
    XCTAssertEqual(state.bufferedDeepLinkCount, 0)
  }

  /// FM1 control: a link that arrives before the first initialize is still
  /// buffered and replayed by it.
  func testADeepLinkBeforeTheFirstInitializeIsStillReplayed() async throws {
    let state = newState()
    state.deepLink(try XCTUnwrap(URL(string: "https://example.com/cold-start")))
    XCTAssertEqual(state.bufferedDeepLinkCount, 1)
    let transport = RecordingEventTransport()
    try await startAndAwaitSentinel(state, transport: transport)

    let sent = await transport.events
    XCTAssertTrue(sent.contains { $0.name == "deep_link" }, "the cold-start link was lost")
    XCTAssertEqual(state.bufferedDeepLinkCount, 0)
  }

  /// K8: the restart defers identity (the Keychain cannot be read), but the
  /// reset is done and the new id is the device's: it is returned, not nil.
  func testAResetWhoseRestartDefersIdentityReturnsTheNewId() async throws {
    let secure = ScriptedSecureStore()
    let state = newState()
    let gate = GatedDeviceReset()
    await gate.release()
    startGatedSandbox(state, gate: gate, secure: secure)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    let old = state.currentDeviceId
    secure.makeUnreadable()

    let new = await state.resetInstall()

    XCTAssertNotNil(new)
    XCTAssertNotEqual(new, old)
    XCTAssertEqual(new, secure.value(DEVICE_ID_KEY))
    XCTAssertFalse(state.isRunning, "precondition: the restart deferred")
  }

  /// K9: a second call while the first is draining is "already running", not
  /// "not running".
  func testACallDuringTheDrainSaysBusy() async throws {
    let transport = GatedRecordingTransport()
    let sink = RecordingLogSink()
    let state = newState()
    let reset = try await startResetInTheDrain(state, transport: transport, sink: sink)

    let second = await state.resetInstall()
    await transport.release()
    _ = await reset.value

    XCTAssertNil(second)
    XCTAssertTrue(sink.lines.contains(RESET_INSTALL_BUSY_LOG), "\(sink.lines)")
    XCTAssertFalse(sink.lines.contains(RESET_INSTALL_NOT_RUNNING_LOG), "\(sink.lines)")
  }

  /// K19/K27: forgetMe, then a re-initialize, both during the drain. The
  /// erasure is complete when forgetMe returns (stop, fence, wipe), so the
  /// re-initialize can only start fresh: a new identity, no consent, no user
  /// id, and nothing ever sent under the erased device id.
  func testForgetMeAndAReinitializeDuringTheDrainStillErase() async throws {
    let transport = GatedRecordingTransport()
    let state = newState()
    let reset = try await startResetInTheDrain(state, transport: transport)
    guard case .found(let old) = KeychainStore().read(DEVICE_ID_KEY) else {
      return XCTFail("precondition: a stored device id")
    }
    state.submit(.setConsent(true))
    state.submit(.setUserId("user-1"))
    state.forgetMe()

    let newTransport = RecordingEventTransport()
    let gate = GatedDeviceReset()
    await gate.release()
    startGatedSandbox(state, gate: gate, transport: newTransport)
    await transport.release()
    let result = await reset.value

    XCTAssertNil(result)
    let now = try XCTUnwrap(state.currentDeviceId)
    XCTAssertNotEqual(now, old, "the re-initialize resolved the erased identity")
    XCTAssertEqual(KeychainStore().read(DEVICE_ID_KEY), .found(now))
    XCTAssertFalse(state.trackingConsent)
    try await Self.until(timeout: 5, state: state) {
      await newTransport.events.contains { $0.type == "install" }
    }
    let defaults = UserDefaultsStore()
    XCTAssertNil(defaults.string(forKey: CONSENT_KEY), "consent survived the erasure")
    XCTAssertNil(defaults.string(forKey: USER_ID_KEY), "user id survived the erasure")
    let underOld = await newTransport.events.filter { $0.deviceId == old }
    XCTAssertTrue(underOld.isEmpty, "an event was sent under the erased device id")
  }

  /// K27 (the store fence): a setting queued on the old pipe before the reset
  /// is written by the draining engine only after the erasure and the
  /// re-initialize. It must not land: nothing is written behind an erasure.
  func testAnOldEngineCannotWriteBehindAnErasure() async throws {
    let transport = GatedRecordingTransport()
    let state = newState()
    defer { UserDefaultsStore().removeObject(forKey: USER_ID_KEY) }
    let gate = GatedDeviceReset()
    await gate.release()
    startGatedSandbox(state, gate: gate, transport: transport)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    state.submit(.track(name: "before_reset", properties: nil, type: "custom"))
    try await Self.until(timeout: 5, state: state) { await transport.sends == 1 }
    // Queued behind the held flush, so the old engine runs them during the drain.
    state.submit(.setUserId("old-user"))
    state.submit(.track(name: "late", properties: nil, type: "custom"))
    state.submit(.flush)
    let reset = Task { await state.resetInstall() }
    try await Self.until(timeout: 5) { !state.isRunning }

    state.forgetMe()
    startGatedSandbox(state, gate: gate, transport: RecordingEventTransport())
    await transport.release()
    _ = await reset.value
    try await Task.sleep(nanoseconds: 200_000_000)

    XCTAssertNil(UserDefaultsStore().string(forKey: USER_ID_KEY), "written behind the erasure")
    let late = await transport.events.filter { $0.name == "late" }
    XCTAssertTrue(late.isEmpty, "uploaded behind the erasure")
  }

  /// K27 (the store fence): without an erasure, the app's settings queued on
  /// the old pipe still land after a re-initialize; they are its latest word.
  func testAnOldEnginesSettingStillLandsAfterAReinitialize() async throws {
    let transport = GatedRecordingTransport()
    let state = newState()
    defer { UserDefaultsStore().removeObject(forKey: USER_ID_KEY) }
    let gate = GatedDeviceReset()
    await gate.release()
    startGatedSandbox(state, gate: gate, transport: transport)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    state.submit(.track(name: "before_reset", properties: nil, type: "custom"))
    try await Self.until(timeout: 5, state: state) { await transport.sends == 1 }
    state.submit(.setUserId("old-user"))
    let reset = Task { await state.resetInstall() }
    try await Self.until(timeout: 5) { !state.isRunning }

    startGatedSandbox(state, gate: gate, transport: RecordingEventTransport())
    await transport.release()
    _ = await reset.value

    try await Self.until(timeout: 5) {
      UserDefaultsStore().string(forKey: USER_ID_KEY) == "old-user"
    }
  }

  /// K23: after shutdown the SDK answers for no device, and the deferred deep
  /// link lookup does not poll.
  func testAStoppedSdkAnswersForNoDevice() async throws {
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(config, transport: RecordingTransport(), sources: Self.settledSources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    state.stop()
    let asked = ErrorContexts()

    let link = await state.fetchDeferredDeepLink(
      makeFetcher: { _, id in
        asked.add(id)
        return StubConversionFetcher(.resolved(DeepLink(deepLinkValue: "promo")))
      },
      sleep: { _ in })

    XCTAssertNil(state.currentDeviceId)
    XCTAssertNil(link)
    XCTAssertTrue(asked.all.isEmpty, "a stopped SDK polled the conversion lookup")
  }

  /// K24: the server-failure line names the failure, never an identifier.
  func testTheServerFailureLineCarriesNoIdentifier() async throws {
    actor LeakyReset: SandboxDeviceResetting {
      func reset(deviceId: String, installationId: String?) async throws { throw LeakyError() }
    }
    let sink = RecordingLogSink()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x", environment: .sandbox)
    config.flushIntervalMs = 0
    state.start(
      config, transport: RecordingTransport(), sources: Self.settledSources, logSink: sink,
      deviceReset: LeakyReset())
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    _ = await state.resetInstall()

    let said = sink.lines.filter { $0.contains("could not reset the server state") }
    XCTAssertEqual(said.count, 1, "\(sink.lines)")
    XCTAssertFalse(said[0].contains("11111111"), said[0])
    XCTAssertTrue(said[0].contains("LeakyError"), said[0])
  }

  /// K25: forgetMe lands after the restart claimed the SDK (here, from the
  /// restart's own first log line). The minted id was erased with everything
  /// else, so the reset returns nil rather than an id the device no longer has.
  func testAnErasureAfterTheClaimReturnsNil() async throws {
    let sink = HookSink()
    let state = newState()
    let gate = GatedDeviceReset()
    await gate.release()
    var config = AdvenueConfig(apiKey: "apk_live_x", environment: .sandbox)
    config.flushIntervalMs = 0
    state.start(
      config, transport: RecordingTransport(), sources: Self.settledSources, logSink: sink,
      deviceReset: gate)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    sink.arm { state.forgetMe() }

    let result = await state.resetInstall()

    XCTAssertNil(result, "returned an id erased after the claim")
  }

  /// K31: with debug logging on, nothing the SDK logs about a failed server
  /// reset carries an identifier, the onError line included.
  func testDebugLoggingOfAServerFailureCarriesNoIdentifier() async throws {
    actor LeakyReset: SandboxDeviceResetting {
      func reset(deviceId: String, installationId: String?) async throws { throw LeakyError() }
    }
    let sink = RecordingLogSink()
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x", environment: .sandbox)
    config.flushIntervalMs = 0
    config.debug = true
    let reported = ErrorContexts()
    config.onError = { context, error in reported.add("\(context): \(error)") }
    state.start(
      config, transport: RecordingTransport(), sources: Self.settledSources, logSink: sink,
      deviceReset: LeakyReset())
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    _ = await state.resetInstall()

    XCTAssertFalse(sink.lines.contains { $0.contains("11111111") }, "\(sink.lines)")
    let server = reported.all.filter { $0.hasPrefix("resetInstall.server") }
    XCTAssertEqual(server, ["resetInstall.server: LeakyError"])
  }

  /// K27: many initialize, forgetMe, stop, resetInstall, setting and deep-link
  /// calls at once, then a final forgetMe racing a re-initialize and resets.
  /// Whatever the interleaving: the erasure is never lost (no consent or user
  /// id survives it, no erased device id comes back), no pipe is orphaned, and
  /// no buffered setting is applied twice.
  func testLifecycleStressKeepsTheInvariants() async throws {
    for round in 0..<8 { try await stressRound(round) }
  }

  private func stressRound(_ round: Int) async throws {
    let state = newState()
    let pipes = PipeLog()
    let applied = ErrorContexts()
    state.onPipeCreated = { pipes.add($0) }
    state.onCarryApplied = { command in
      if case .setUserId(let id?) = command { applied.add(id) }
    }
    let transport = RecordingEventTransport()
    let resets = TaskLog()
    let sources = Self.settledSources
    let start: @Sendable () -> Void = {
      var config = AdvenueConfig(apiKey: "apk_live_x", environment: .sandbox)
      config.flushIntervalMs = 0
      state.start(
        config, transport: transport, sources: sources, deviceReset: RecordingDeviceReset())
    }
    start()
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    defer {
      let defaults = UserDefaultsStore()
      defaults.removeObject(forKey: CONSENT_KEY)
      defaults.removeObject(forKey: USER_ID_KEY)
    }

    DispatchQueue.concurrentPerform(iterations: 60) { i in
      switch i % 6 {
      case 0: start()
      case 1: resets.add(Task { await state.resetInstall() })
      case 2:
        state.submit(.setUserId("r\(round)-\(i)"))
        state.submit(.setConsent(i % 4 == 0))
      case 3: state.forgetMe()
      case 4: state.stop()
      default: state.deepLink(URL(string: "https://example.com/\(i)")!)
      }
    }
    for task in resets.drain() { _ = await task.value }

    var erasedIds = Set(await transport.events.compactMap(\.deviceId))
    if let id = state.currentDeviceId { erasedIds.insert(id) }
    if case .found(let id) = KeychainStore().read(DEVICE_ID_KEY) { erasedIds.insert(id) }

    DispatchQueue.concurrentPerform(iterations: 4) { i in
      switch i {
      case 0: state.forgetMe()
      case 1: start()
      default: resets.add(Task { await state.resetInstall() })
      }
    }
    for task in resets.drain() { _ = await task.value }
    try await Task.sleep(nanoseconds: 300_000_000)

    // The erasure is never lost, and no setting is applied after it.
    let defaults = UserDefaultsStore()
    XCTAssertNil(defaults.string(forKey: CONSENT_KEY), "round \(round): consent survived")
    XCTAssertNil(defaults.string(forKey: USER_ID_KEY), "round \(round): user id survived")
    if case .found(let id) = KeychainStore().read(DEVICE_ID_KEY) {
      XCTAssertFalse(erasedIds.contains(id), "round \(round): an erased device id came back")
    }
    if let id = state.currentDeviceId {
      XCTAssertFalse(erasedIds.contains(id), "round \(round): running under an erased id")
    }
    // Buffered settings are applied at most once.
    XCTAssertEqual(applied.all.count, Set(applied.all).count, "round \(round): applied twice")
    // No pipe is orphaned: at most the live one is unfinished, and none after stop.
    let unfinished = pipes.all.filter { !$0.isFinished }
    XCTAssertLessThanOrEqual(unfinished.count, 1, "round \(round)")
    if !unfinished.isEmpty { XCTAssertTrue(state.isRunning, "round \(round): orphaned pipe") }
    state.stop()
    XCTAssertTrue(pipes.all.allSatisfy(\.isFinished), "round \(round): a pipe outlived stop")
  }

  /// K17: resolveDeferredDeepLink asks the server for this device, with the
  /// config the SDK was started with. It returned nil without asking anyone:
  /// the config it read was never recorded.
  func testResolveDeferredDeepLinkAsksForThisDevice() async throws {
    let state = newState()
    var config = AdvenueConfig(apiKey: "apk_live_x")
    config.flushIntervalMs = 0
    state.start(config, transport: RecordingTransport(), sources: Self.settledSources)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    let deviceId = try XCTUnwrap(state.currentDeviceId)
    let asked = ErrorContexts()

    let link = await state.fetchDeferredDeepLink(
      makeFetcher: { started, id in
        asked.add("\(started.apiKey)|\(id)")
        return StubConversionFetcher(.resolved(DeepLink(deepLinkValue: "promo")))
      },
      sleep: { _ in })

    XCTAssertEqual(asked.all, ["apk_live_x|\(deviceId)"])
    XCTAssertEqual(link?.deepLinkValue, "promo")
  }

  /// I1: `shutdown()` while the server call is out. The reset must not revive
  /// the stopped SDK, and must not rotate the identity.
  func testStopDuringTheServerCallCancelsTheReset() async throws {
    let gate = GatedDeviceReset()
    let state = newState()
    startGatedSandbox(state, gate: gate)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    let old = state.currentDeviceId
    let oldInstallation = UserDefaultsStore().string(forKey: INSTALLATION_ID_KEY)

    let reset = Task { await state.resetInstall() }
    try await Self.until(timeout: 5) { await gate.calls == 1 }
    state.stop()
    await gate.release()
    let result = await reset.value

    XCTAssertNil(result)
    XCTAssertFalse(state.isRunning, "a stopped SDK was restarted")
    XCTAssertEqual(KeychainStore().read(DEVICE_ID_KEY), old.map { .found($0) })
    XCTAssertEqual(UserDefaultsStore().string(forKey: INSTALLATION_ID_KEY), oldInstallation)
  }

  /// I1: a re-initialize while the server call is out owns the SDK from then
  /// on; the reset gives up rather than tearing that instance down.
  func testReinitializeDuringTheServerCallCancelsTheReset() async throws {
    let gate = GatedDeviceReset()
    let state = newState()
    startGatedSandbox(state, gate: gate)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    let old = state.currentDeviceId

    let reset = Task { await state.resetInstall() }
    try await Self.until(timeout: 5) { await gate.calls == 1 }
    startGatedSandbox(state, gate: gate)
    await gate.release()
    let result = await reset.value

    XCTAssertNil(result)
    XCTAssertTrue(state.isRunning, "the re-initialized SDK was torn down")
    XCTAssertEqual(state.currentDeviceId, old)
  }

  /// I1: a double tap. The first call resets; the second, made while the first
  /// waits on the server, is refused (nil, logged) and touches nothing. The
  /// event queued before the reset is never sent.
  func testASecondResetWhileOneIsInFlightIsRefused() async throws {
    let gate = GatedDeviceReset()
    let sink = RecordingLogSink()
    let transport = RecordingEventTransport()
    let state = newState()
    startGatedSandbox(state, gate: gate, transport: transport, sink: sink)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    let old = try XCTUnwrap(state.currentDeviceId)
    state.submit(.track(name: "before_reset", properties: nil, type: "custom"))

    let first = Task { await state.resetInstall() }
    try await Self.until(timeout: 5) { await gate.calls == 1 }
    let second = await state.resetInstall()
    XCTAssertNil(second)
    XCTAssertTrue(sink.lines.contains(RESET_INSTALL_BUSY_LOG), "\(sink.lines)")
    await gate.release()
    let firstResult = await first.value
    let new = try XCTUnwrap(firstResult)

    XCTAssertNotEqual(new, old)
    let calls = await gate.calls
    XCTAssertEqual(calls, 1, "one reset reached the server")
    try await Self.until(timeout: 5, state: state) {
      await transport.events.contains { $0.type == "install" && $0.deviceId == new }
    }
    // The install flow's own flush may send it before the reset is taken (the
    // gate holds the reset long enough); what must never happen is a second
    // send, or one under the new device.
    let sent = await transport.events.filter { $0.name == "before_reset" }
    XCTAssertLessThanOrEqual(sent.count, 1, "the old queue was resent")
    XCTAssertFalse(sent.contains { $0.deviceId == new }, "an old event moved to the new device")
  }

  /// F13: consent and the user id set while the reset drains (pipe detached,
  /// waiting behind a slow flush) reach the restarted engine, and the
  /// consent getter does not fall back to the value the drain started with.
  func testConsentAndUserIdSetDuringTheDrainSurviveTheReset() async throws {
    let gate = GatedDeviceReset()
    await gate.release()
    let transport = GatedTransport()
    let state = newState()
    let applied = ErrorContexts()
    state.onCarryApplied = { command in
      if case .setUserId(let id?) = command { applied.add(id) }
    }
    startGatedSandbox(state, gate: gate, transport: transport)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")
    state.rememberConsent(true)
    state.submit(.setConsent(true))
    state.submit(.setUserId("user-1"))
    state.submit(.track(name: "before_reset", properties: nil, type: "custom"))
    try await Self.until(timeout: 5, state: state) { await transport.sends == 1 }

    let reset = Task { await state.resetInstall() }
    try await Self.until(timeout: 5) { !state.isRunning }
    state.rememberConsent(false)
    state.submit(.setConsent(false))
    state.submit(.setUserId("user-2"))
    await transport.release()
    let result = await reset.value
    _ = try XCTUnwrap(result)

    XCTAssertFalse(state.trackingConsent, "the getter fell back to the pre-reset consent")
    try await Self.until(timeout: 5) {
      let defaults = UserDefaultsStore()
      return defaults.string(forKey: CONSENT_KEY) == "denied"
        && defaults.string(forKey: USER_ID_KEY) == "user-2"
    }
    // K27: the buffered setting was applied once, by the restart, not again by the settle.
    XCTAssertEqual(applied.all, ["user-2"])
  }

  /// F14: forgetMe while the server call is out cancels the reset: the erased
  /// SDK is not restarted under a fresh identity.
  func testForgetMeDuringTheServerCallCancelsTheReset() async throws {
    let gate = GatedDeviceReset()
    let state = newState()
    startGatedSandbox(state, gate: gate)
    try XCTSkipIf(state.currentDeviceId == nil, "identity deferred in this environment")

    let reset = Task { await state.resetInstall() }
    try await Self.until(timeout: 5) { await gate.calls == 1 }
    state.forgetMe()
    await gate.release()
    let result = await reset.value

    XCTAssertNil(result, "the reset restarted an erased SDK")
    XCTAssertNil(state.currentDeviceId, "a fresh identity was minted after forgetMe")
  }

  /// M2: production says so even before initialize.
  func testResetInstallBeforeInitializeLogsTheProductionLine() async {
    let sink = RecordingLogSink()
    let state = FacadeState(fallbackSink: sink)
    states.append(state)
    let result = await state.resetInstall()
    XCTAssertNil(result)
    XCTAssertEqual(sink.lines, [RESET_INSTALL_PRODUCTION_LOG])
  }

  /// M2: a sandbox SDK that is not running says why, without identifiers.
  func testResetInstallOnAStoppedSandboxSaysSo() async throws {
    let gate = GatedDeviceReset()
    let sink = RecordingLogSink()
    let state = newState()
    startGatedSandbox(state, gate: gate, sink: sink)
    state.stop()
    let result = await state.resetInstall()
    XCTAssertNil(result)
    XCTAssertTrue(sink.lines.contains(RESET_INSTALL_NOT_RUNNING_LOG), "\(sink.lines)")
    let calls = await gate.calls
    XCTAssertEqual(calls, 0)
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

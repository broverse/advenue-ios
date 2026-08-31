import AdvenueCore
import Foundation

/// Spec §5: the install waits this long for enrichment and no longer. Matches
/// the deadlines the RN SDK already uses (SKAN config 3000 ms).
public let INSTALL_WINDOW_MS = 3_000

/// What the install event carries beyond the envelope every event has.
public struct Enrichment: Sendable, Equatable {
  public var attestation: AttestationResult?
  public var attestationChallenge: String?
  public var idfa: String?
  public var vendorId: String?
  public var appInstanceId: String?
  public var adservicesToken: String?

  public init(
    idfa: String? = nil, vendorId: String? = nil,
    appInstanceId: String? = nil, adservicesToken: String? = nil,
    attestation: AttestationResult? = nil, attestationChallenge: String? = nil
  ) {
    self.attestation = attestation
    self.attestationChallenge = attestationChallenge
    self.idfa = idfa
    self.vendorId = vendorId
    self.appInstanceId = appInstanceId
    self.adservicesToken = adservicesToken
  }
}

/// The capabilities the collector draws on, injected so the deadline behaviour
/// is testable without ATT, AdServices or Firebase — none of which a simulator
/// can exercise.
public struct EnrichmentSources: Sendable {
  public var searchAdsToken: @Sendable () async -> String?
  public var advertisingId: @Sendable () -> (idfa: String?, vendorId: String?)
  public var appInstanceId: @Sendable () async -> String?
  /// Returns the attested challenge and its result, or nil. Every failure path
  /// — unsupported device, challenge fetch, attest — yields nil, because an
  /// install held for attestation is an install lost.
  public var attestation: @Sendable () async -> (challenge: String, result: AttestationResult)?

  public init(
    searchAdsToken: @escaping @Sendable () async -> String?,
    advertisingId: @escaping @Sendable () -> (idfa: String?, vendorId: String?),
    appInstanceId: @escaping @Sendable () async -> String?,
    attestation: @escaping @Sendable () async -> (challenge: String, result: AttestationResult)? = {
      nil
    }
  ) {
    self.searchAdsToken = searchAdsToken
    self.advertisingId = advertisingId
    self.appInstanceId = appInstanceId
    self.attestation = attestation
  }

  /// Production wiring. `AdvertisingIdentity.advertisingId` already returns nil
  /// unless ATT is authorized, so the SDK never ships the zero UUID — which
  /// would be worse than nothing, because it looks like an identifier.
  public static func system(
    appInstanceIdProvider: (@Sendable () async -> String?)? = nil,
    attestation: (@Sendable () async -> (challenge: String, result: AttestationResult)?)? = nil
  ) -> EnrichmentSources {
    EnrichmentSources(
      searchAdsToken: { await SearchAdsTokenFetcher().token() },
      advertisingId: {
        let identity = AdvertisingIdentity()
        return (idfa: identity.advertisingId, vendorId: identity.vendorId)
      },
      appInstanceId: { await appInstanceIdProvider?() },
      attestation: { await attestation?() })
  }
}

/// Collects what is ready before `deadlineMs` and returns; a source still
/// running when the deadline expires contributes nothing.
///
/// The deadline is hard by design (spec §5). The AdServices retry can still be
/// in flight when it expires, and the install is sent regardless: a token that
/// arrives afterwards rides the next event, whereas a delayed install shifts
/// every attribution window behind it.
public func collectEnrichment(
  _ sources: EnrichmentSources,
  deadlineMs: Int
) async -> Enrichment {
  // Synchronous reads; no reason to race them.
  let ids = sources.advertisingId()
  var result = Enrichment(idfa: ids.idfa, vendorId: ids.vendorId)

  await withTaskGroup(of: (String, String?).self) { group in
    group.addTask { ("adservices", await sources.searchAdsToken()) }
    group.addTask { ("appInstance", await sources.appInstanceId()) }
    group.addTask {
      try? await Task.sleep(nanoseconds: UInt64(deadlineMs) * 1_000_000)
      return ("deadline", nil)
    }

    var settled = 0
    for await (key, value) in group {
      if key == "deadline" { break }
      if key == "adservices" { result.adservicesToken = value }
      if key == "appInstance" { result.appInstanceId = value }
      settled += 1
      if settled == 2 { break }
    }
    group.cancelAll()
  }

  // Attestation is two round trips — challenge, then attest — and is raced by
  // the same deadline as everything else. An `async let` awaited here would
  // NOT be bounded: it would hold the install for as long as Apple took, which
  // is the one thing enrichment must never do.
  if let attested = await withDeadline(ms: deadlineMs, { await sources.attestation() }) {
    result.attestation = attested?.result
    result.attestationChallenge = attested?.challenge
  }

  return result
}

/// Runs `work` and gives up at the deadline. Returns nil when the deadline won,
/// which the caller treats the same as "the source had nothing".
func withDeadline<T: Sendable>(
  ms: Int, _ work: @escaping @Sendable () async -> T
) async -> T? {
  await withTaskGroup(of: Optional<T>.self) { group in
    group.addTask { await work() }
    group.addTask {
      try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
      return nil
    }
    let first = await group.next() ?? nil
    group.cancelAll()
    return first
  }
}

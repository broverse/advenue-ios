import Foundation

/// The wire envelope, mirroring `clientEventSchema` in
/// `packages/shared/src/events.ts`.
///
/// Every optional is genuinely optional on the wire: the server uses zod
/// `.optional()`, which accepts a missing key and **rejects** an explicit
/// `null`. Swift's synthesised encoder omits nil for optional properties,
/// which is the behaviour required here — a hand-written encoder emitting
/// `null` would 400 the whole batch.
public struct ClientEvent: Codable, Sendable, Equatable {
  public var id: String
  public var deviceId: String
  public var installationId: String?
  public var type: String
  public var name: String
  public var timestamp: String
  public var platform: String
  public var osVersion: String?
  public var appVersion: String?
  public var sdkVersion: String?
  public var network: String?
  public var campaign: String?
  public var country: String?
  public var idfa: String?
  public var gaid: String?
  public var limitAdTracking: Bool?
  public var vendorId: String?
  public var androidId: String?
  public var customerUserId: String?
  public var appInstanceId: String?
  public var consent: Consent?
  public var properties: [String: AdvenueValue]?
  public var pushToken: String?
  public var pushProvider: String?
  public var attestationToken: String?
  public var attestationType: String?
  public var attestationKeyId: String?
  public var attestationChallenge: String?
  public var deviceCheckToken: String?
  public var adservicesToken: String?

  public init(
    id: String, deviceId: String, type: String, name: String, timestamp: String, platform: String
  ) {
    self.id = id
    self.deviceId = deviceId
    self.type = type
    self.name = name
    self.timestamp = timestamp
    self.platform = platform
  }

  /// Required for the queue's reload path. `properties` is deliberately not
  /// decoded: nothing reads it back, and giving `AdvenueValue` a Decodable
  /// conformance would mean accepting arbitrary JSON into a closed type.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    deviceId = try c.decode(String.self, forKey: .deviceId)
    type = try c.decode(String.self, forKey: .type)
    name = try c.decode(String.self, forKey: .name)
    timestamp = try c.decode(String.self, forKey: .timestamp)
    platform = try c.decode(String.self, forKey: .platform)
    installationId = try c.decodeIfPresent(String.self, forKey: .installationId)
    osVersion = try c.decodeIfPresent(String.self, forKey: .osVersion)
    appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
    sdkVersion = try c.decodeIfPresent(String.self, forKey: .sdkVersion)
    network = try c.decodeIfPresent(String.self, forKey: .network)
    campaign = try c.decodeIfPresent(String.self, forKey: .campaign)
    country = try c.decodeIfPresent(String.self, forKey: .country)
    idfa = try c.decodeIfPresent(String.self, forKey: .idfa)
    gaid = try c.decodeIfPresent(String.self, forKey: .gaid)
    limitAdTracking = try c.decodeIfPresent(Bool.self, forKey: .limitAdTracking)
    vendorId = try c.decodeIfPresent(String.self, forKey: .vendorId)
    androidId = try c.decodeIfPresent(String.self, forKey: .androidId)
    customerUserId = try c.decodeIfPresent(String.self, forKey: .customerUserId)
    appInstanceId = try c.decodeIfPresent(String.self, forKey: .appInstanceId)
    pushToken = try c.decodeIfPresent(String.self, forKey: .pushToken)
    pushProvider = try c.decodeIfPresent(String.self, forKey: .pushProvider)
    attestationToken = try c.decodeIfPresent(String.self, forKey: .attestationToken)
    attestationType = try c.decodeIfPresent(String.self, forKey: .attestationType)
    attestationKeyId = try c.decodeIfPresent(String.self, forKey: .attestationKeyId)
    attestationChallenge = try c.decodeIfPresent(String.self, forKey: .attestationChallenge)
    deviceCheckToken = try c.decodeIfPresent(String.self, forKey: .deviceCheckToken)
    adservicesToken = try c.decodeIfPresent(String.self, forKey: .adservicesToken)
    consent = try c.decodeIfPresent(Consent.self, forKey: .consent)
    properties = nil
  }
}

public enum EventEncoding {
  /// Milliseconds-since-epoch to the exact form TypeScript's `toISOString()`
  /// produces: always three fractional digits, always `Z`. Foundation's
  /// `.iso8601` strategy drops fractional seconds entirely, which would change
  /// every timestamp on the wire.
  public static func iso8601(ms: Int64) -> String {
    // Floor to the second so a negative millisecond remainder cannot borrow
    // from the second field.
    let wholeSeconds = Int64((Double(ms) / 1000.0).rounded(.down))
    let millis = ms - wholeSeconds * 1000
    let date = Date(timeIntervalSince1970: Double(wholeSeconds))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(
      format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, Int(millis))
  }

  /// The canonical JSON encoder: keys sorted so output is byte-comparable with
  /// the conformance snapshots, and nothing pretty-printed on the wire.
  public static func canonicalEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

extension ClientEvent {
  /// The exact bytes this event puts on the wire.
  public func encodeCanonical() throws -> String {
    let data = try EventEncoding.canonicalEncoder().encode(self)
    return String(decoding: data, as: UTF8.self)
  }
}

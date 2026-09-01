import Foundation

/// A JSON value an event property may hold.
///
/// The server accepts `z.record(z.string(), z.unknown())`, and Swift has no
/// safe `[String: Any]` Codable — an unencodable value would trap at runtime,
/// inside the SDK, in someone else's app. A closed enum makes that a compile
/// error instead, and the literal conformances keep the call site looking like
/// the dictionary a caller expects to write:
///
///     Advenue.track("purchase", properties: ["price": 9.99, "tier": "gold"])
public enum AdvenueValue: Sendable, Equatable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case array([AdvenueValue])
  case object([String: AdvenueValue])
  case null
}

extension AdvenueValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}
extension AdvenueValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) { self = .int(value) }
}
extension AdvenueValue: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) { self = .double(value) }
}
extension AdvenueValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension AdvenueValue: ExpressibleByNilLiteral {
  public init(nilLiteral: ()) { self = .null }
}
extension AdvenueValue: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: AdvenueValue...) { self = .array(elements) }
}
extension AdvenueValue: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, AdvenueValue)...) {
    self = .object(Dictionary(uniqueKeysWithValues: elements))
  }
}

extension AdvenueValue: Encodable {
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let v): try container.encode(v)
    case .int(let v): try container.encode(v)
    case .double(let v): try container.encode(v)
    case .bool(let v): try container.encode(v)
    case .array(let v): try container.encode(v)
    case .object(let v): try container.encode(v)
    case .null: try container.encodeNil()
    }
  }
}

/// Reads back exactly what `Encodable` above writes, and refuses anything else.
///
/// The closed type exists to protect the CALL SITE — a caller must not be able
/// to hand the SDK a value it cannot encode. Decoding is the other direction:
/// these bytes were written from an `AdvenueValue`, so accepting the shapes it
/// can represent takes nothing away from that guarantee. Anything outside them
/// throws, and `EventQueue.load` already turns a throwing blob into an empty
/// queue rather than bricking the SDK.
///
/// Order matters. `Int` is tried before `Double`, because a decoder that read
/// `3` as `3.0` would restore the property and silently change its type on the
/// wire — a quieter version of the bug this conformance exists to fix.
extension AdvenueValue: Decodable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let v = try? container.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? container.decode(Int.self) {
      self = .int(v)
    } else if let v = try? container.decode(Double.self) {
      self = .double(v)
    } else if let v = try? container.decode(String.self) {
      self = .string(v)
    } else if let v = try? container.decode([AdvenueValue].self) {
      self = .array(v)
    } else if let v = try? container.decode([String: AdvenueValue].self) {
      self = .object(v)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "not a value AdvenueValue can represent")
    }
  }
}

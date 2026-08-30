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

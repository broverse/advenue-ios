import Foundation
import XCTest

/// One conformance vector: the shared contract every SDK implementation runs.
/// `name` and `source` are guaranteed by the canonical loader; `body` carries
/// the kind-specific fields.
struct Vector {
  let file: String
  let name: String
  let source: String
  let body: [String: Any]

  func value<T>(_ key: String, as: T.Type = T.self) throws -> T {
    guard let v = body[key] as? T else {
      throw VectorError.missingField(file: file, key: key)
    }
    return v
  }

  func optional<T>(_ key: String, as: T.Type = T.self) -> T? {
    body[key] as? T
  }
}

enum VectorError: Error, CustomStringConvertible {
  case missingDirectory(String)
  case missingField(file: String, key: String)
  case missingSource(String)

  var description: String {
    switch self {
    case .missingDirectory(let kind):
      return "no vectors bundled for kind \(kind) — run `pnpm conformance:sync`"
    case .missingField(let file, let key):
      return "\(file): missing field \(key)"
    case .missingSource(let file):
      return "\(file): missing \"source\" — every vector must cite its authority"
    }
  }
}

/// Every vector of one kind, sorted by filename so a run is reproducible.
/// Mirrors the authority rule of the canonical loader: a vector with no
/// `source` is an error, not a warning.
func loadVectors(_ kind: String) throws -> [Vector] {
  guard let root = Bundle.module.url(forResource: "vectors", withExtension: nil) else {
    throw VectorError.missingDirectory(kind)
  }
  let dir = root.appendingPathComponent(kind)
  let files = try FileManager.default
    .contentsOfDirectory(atPath: dir.path)
    .filter { $0.hasSuffix(".json") }
    .sorted()
  return try files.map { file in
    let data = try Data(contentsOf: dir.appendingPathComponent(file))
    guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw VectorError.missingField(file: file, key: "<root object>")
    }
    guard let source = body["source"] as? String, !source.isEmpty else {
      throw VectorError.missingSource(file)
    }
    guard let name = body["name"] as? String, !name.isEmpty else {
      throw VectorError.missingField(file: file, key: "name")
    }
    return Vector(file: file, name: name, source: source, body: body)
  }
}

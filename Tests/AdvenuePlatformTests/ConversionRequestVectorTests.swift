import Foundation
import XCTest

@testable import AdvenuePlatform

/// Y-LINKS-1: `/sdk/conversion-data` refused the project key the dashboard
/// mints, because the request named no platform and a project key spans
/// listings. The request now names it; the Kotlin SDK runs the same vectors.
final class ConversionRequestVectorTests: XCTestCase {
  func testTheConversionRequestMatchesTheVectors() throws {
    guard let root = Bundle.module.url(forResource: "vectors", withExtension: nil) else {
      return XCTFail("vectors not bundled — run `pnpm conformance:sync`")
    }
    let dir = root.appendingPathComponent("conversion-request")
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter { $0.hasSuffix(".json") }.sorted()
    XCTAssertFalse(files.isEmpty)

    for file in files {
      let data = try Data(contentsOf: dir.appendingPathComponent(file))
      let vector = try JSONSerialization.jsonObject(with: data) as! [String: Any]
      let input = vector["input"] as! [String: String]
      let expected = vector["expected"] as! [String: Any]
      let urls = expected["url"] as! [String: String]
      let headers = expected["headers"] as! [String: String]

      let request = HttpConversionFetcher(
        endpoint: input["endpoint"]!, apiKey: input["apiKey"]!, deviceId: input["deviceId"]!
      ).buildRequest()

      XCTAssertEqual(request.url?.absoluteString, urls["ios"], file)
      XCTAssertEqual(request.httpMethod, expected["method"] as? String, file)
      for (name, value) in headers {
        XCTAssertEqual(request.value(forHTTPHeaderField: name), value, "\(file) \(name)")
      }
    }
  }
}

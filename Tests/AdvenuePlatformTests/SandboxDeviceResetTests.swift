import AdvenueCore
import Foundation
import XCTest

@testable import AdvenuePlatform

final class SandboxDeviceResetTests: XCTestCase {
  struct FixedClock: Clock {
    let ms: Int64
    func nowMs() -> Int64 { ms }
  }

  func testRequestShapeAndSignature() throws {
    let reset = HttpSandboxDeviceReset(
      endpoint: "https://ingest.example", apiKey: "apk_live_x", signingSecret: "sk",
      clock: FixedClock(ms: 1_792_058_400_000))
    let request = try reset.buildRequest(deviceId: "dev-1", installationId: "inst-1")
    XCTAssertEqual(request.url?.absoluteString, "https://ingest.example/v1/sandbox/reset-device")
    XCTAssertEqual(request.httpMethod, "POST")
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    let json =
      try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
    XCTAssertEqual(
      json,
      ["apiKey": "apk_live_x", "platform": "ios", "deviceId": "dev-1", "installationId": "inst-1"])
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Advenue-Timestamp"), "1792058400000")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "X-Advenue-Signature"),
      signRequest(CryptoKitSigner(), secret: "sk", timestamp: "1792058400000", body: body))
  }

  func testUnsignedWithoutSecretAndNoInstallationField() throws {
    let request = try HttpSandboxDeviceReset(apiKey: "apk_live_x")
      .buildRequest(deviceId: "d", installationId: nil)
    XCTAssertNil(request.value(forHTTPHeaderField: "X-Advenue-Signature"))
    let json =
      try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
    XCTAssertNotNil(json)
    XCTAssertNil(json?["installationId"])
  }
}

import Foundation
import XCTest

@testable import AdvenueCore
@testable import AdvenuePlatform

private struct FrozenClock: Clock {
  let ms: Int64
  func nowMs() -> Int64 { ms }
}

final class TransportTests: XCTestCase {
  private func event() -> ClientEvent {
    ClientEvent(
      id: "e-1", deviceId: "dev-1", type: "custom", name: "purchase",
      timestamp: "2026-01-01T00:00:00.000Z", platform: "ios")
  }

  func testUnsignedRequestShape() throws {
    let transport = HttpTransport(endpoint: "https://ingest.test", apiKey: "apk_live_x")
    let request = try transport.buildRequest([event()])

    XCTAssertEqual(request.url?.absoluteString, "https://ingest.test/v1/events")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
    XCTAssertNil(request.value(forHTTPHeaderField: "X-Advenue-Signature"))

    let body = String(decoding: request.httpBody!, as: UTF8.self)
    // apiKey travels in the body, and the batch is key-sorted like every other
    // canonical encoding in this SDK.
    XCTAssertTrue(body.hasPrefix(#"{"apiKey":"apk_live_x","events":["#), body)
    // zod .optional() rejects an explicit null, so a null anywhere in the body
    // would 400 the whole batch.
    XCTAssertFalse(body.contains("null"), body)
  }

  func testSignedRequestBindsTheTimestamp() throws {
    let transport = HttpTransport(
      endpoint: "https://ingest.test", apiKey: "apk_live_x",
      signingSecret: "sk_test_conformance", clock: FrozenClock(ms: 1_767_225_600_000))
    let request = try transport.buildRequest([event()])

    let timestamp = request.value(forHTTPHeaderField: "X-Advenue-Timestamp")
    XCTAssertEqual(timestamp, "1767225600000")

    let body = String(decoding: request.httpBody!, as: UTF8.self)
    let expected = signRequest(
      CryptoKitSigner(), secret: "sk_test_conformance", timestamp: timestamp!, body: body)
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Advenue-Signature"), expected)
    // The signature covers the body it was computed over, not a re-encoding:
    // a second encode with different key order would verify against nothing.
    XCTAssertEqual(expected.count, 64)
  }

  /// F-SDK-10: with no response at all there is no HTTP status to report. The
  /// failure stays 408 for the backoff (retryable, like sdk-core), but what is
  /// logged says it was the network, not a 408 the server never sent.
  func testANetworkFailureIsReportedAsANetworkErrorNotAnHTTP408() async {
    // Port 1 on loopback: refused at once, no DNS and no real network.
    let transport = HttpTransport(endpoint: "https://127.0.0.1:1", apiKey: "apk_live_x")
    do {
      try await transport.send([event()])
      XCTFail("the send must fail")
    } catch let error as IngestError {
      XCTAssertTrue(error.isRetryable)
      XCTAssertEqual(error.status, 408)
      let text = "\(error)"
      XCTAssertTrue(text.contains("network error"), text)
      XCTAssertFalse(text.contains("408"), text)
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  func testAnHTTPFailureStillNamesItsStatus() {
    XCTAssertEqual("\(IngestError(status: 503))", "IngestError(status: 503)")
  }

  func testStatusClassificationMatchesTheBackoffVectors() {
    XCTAssertTrue(IngestError(status: 429).isRetryable)
    XCTAssertTrue(IngestError(status: 503).isRetryable)
    XCTAssertTrue(IngestError(status: 408).isRetryable)
    XCTAssertFalse(IngestError(status: 400).isRetryable)
    XCTAssertFalse(IngestError(status: 413).isRetryable)
  }

  func testBatchCapMatchesTheSchema() {
    XCTAssertEqual(MAX_BATCH_SIZE, 100)
  }
}

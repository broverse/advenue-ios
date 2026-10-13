import Foundation
import XCTest

@testable import AdvenueCore
@testable import AdvenuePlatform

final class SandboxTransportTests: XCTestCase {
  private func event() -> ClientEvent {
    ClientEvent(
      id: "e-1", deviceId: "dev-1", type: "custom", name: "purchase",
      timestamp: "2026-01-01T00:00:00.000Z", platform: "ios")
  }

  func testSandboxBatchCarriesTheFieldAndProductionDoesNot() throws {
    let sandbox = HttpTransport(endpoint: "https://ingest.test", apiKey: "k", environment: .sandbox)
    let body = String(decoding: try sandbox.buildRequest([event()]).httpBody!, as: UTF8.self)
    XCTAssertTrue(body.contains(#""environment":"sandbox""#), body)

    let production = HttpTransport(endpoint: "https://ingest.test", apiKey: "k")
    let plain = String(decoding: try production.buildRequest([event()]).httpBody!, as: UTF8.self)
    XCTAssertFalse(plain.contains("environment"), "production bytes stay identical to 1.3.0")
  }

  func testA2xxWithoutTheSandboxEchoStopsUploads() {
    let body = Data(#"{"ok":true,"appId":"a1","accepted":1}"#.utf8)
    XCTAssertThrowsError(try HttpTransport.interpret(status: 202, body: body, environment: .sandbox)) {
      XCTAssertEqual($0 as? SandboxUnsupportedError, SandboxUnsupportedError(.responseMismatch))
    }
    XCTAssertEqual(
      try HttpTransport.interpret(status: 202, body: body, environment: .production), "a1")
    let echoed = Data(#"{"ok":true,"appId":"a1","environment":"sandbox"}"#.utf8)
    XCTAssertEqual(try HttpTransport.interpret(status: 202, body: echoed, environment: .sandbox), "a1")
  }

  func testTheQuotaAnswerCarriesItsReset() {
    let body = Data(
      #"{"error":"sandbox_quota_exceeded","resetAt":"2026-10-14T00:00:00.000Z","resetAtMs":1760400000000}"#
        .utf8)
    XCTAssertThrowsError(try HttpTransport.interpret(status: 429, body: body, environment: .sandbox)) {
      XCTAssertEqual(($0 as? IngestError)?.quotaResetAtMs, 1_760_400_000_000)
    }
    XCTAssertThrowsError(
      try HttpTransport.interpret(status: 429, body: Data("{}".utf8), environment: .sandbox)
    ) {
      XCTAssertNil(($0 as? IngestError)?.quotaResetAtMs, "a plain 429 still backs off")
    }
  }

  func testHealthParsing() {
    XCTAssertTrue(healthAdvertisesSandbox(Data(#"{"ok":true,"capabilities":["sandbox"]}"#.utf8)))
    XCTAssertFalse(healthAdvertisesSandbox(Data(#"{"ok":true,"service":"advenue-ingestion"}"#.utf8)))
    XCTAssertFalse(healthAdvertisesSandbox(Data("<html>".utf8)))
  }

  func testCapabilityIsAskedOncePerProcess() async throws {
    let calls = Locked(0)
    let capability = SandboxCapability(probe: {
      calls.mutate { $0 += 1 }
      return (200, Data(#"{"capabilities":["sandbox"]}"#.utf8))
    })
    _ = try await capability.check()
    let second = try await capability.check()
    XCTAssertTrue(second)
    XCTAssertEqual(calls.value, 1)
  }

  func testAMissingCapabilityIsFinal() async throws {
    let capability = SandboxCapability(probe: { (200, Data(#"{"ok":true}"#.utf8)) })
    let supported = try await capability.check()
    XCTAssertFalse(supported)
  }

  /// [RF-3] A network failure or a 5xx is not proof of an old server.
  func testAnUnreachableHealthIsRetriedNotCached() async throws {
    let answers = Locked<[Result<(Int, Data), any Error>]>([
      .failure(URLError(.timedOut)),
      .success((503, Data())),
      .success((200, Data(#"{"capabilities":["sandbox"]}"#.utf8))),
    ])
    let capability = SandboxCapability(probe: {
      var next: Result<(Int, Data), any Error>!
      answers.mutate { next = $0.removeFirst() }
      let (status, body) = try next.get()
      return (status, body)
    })
    do {
      _ = try await capability.check()
      XCTFail("a timeout must throw")
    } catch let error as IngestError { XCTAssertTrue(error.isRetryable) }
    do {
      _ = try await capability.check()
      XCTFail("a 503 must throw")
    } catch let error as IngestError { XCTAssertTrue(error.isRetryable) }
    let supported = try await capability.check()
    XCTAssertTrue(supported)
  }

  func testConversionFetcherAsksForSandboxData() {
    let sandbox = HttpConversionFetcher(
      endpoint: "https://api.test", apiKey: "k", deviceId: "d1", environment: .sandbox)
    XCTAssertTrue(sandbox.buildRequest().url!.absoluteString.hasSuffix("&environment=sandbox"))
    let production = HttpConversionFetcher(endpoint: "https://api.test", apiKey: "k", deviceId: "d1")
    XCTAssertFalse(production.buildRequest().url!.absoluteString.contains("environment"))
  }
}

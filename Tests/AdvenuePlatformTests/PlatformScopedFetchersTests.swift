import Foundation
import XCTest

@testable import AdvenuePlatform

/// N1: a project-scoped API key narrows to a listing via `?platform=` /
/// `?store=` (see `resolveProjectListing` in apps/ingestion/src/app.ts), but
/// no shipped SDK sent those query parameters — so a project key on a normal
/// two-listing (iOS + Android) product got `400 unresolved_scope` on both
/// `/v1/sdk-config` and `/v1/attest/challenge`, silently disabling SKAN
/// conversion-value config and the attestation challenge.
///
/// These fetchers are iOS-only by construction, so they can always send
/// `?platform=ios` and let the server's narrowing resolve unambiguously.
final class PlatformScopedFetchersTests: XCTestCase {
  func testSkanConfigFetchRequestNamesThePlatform() {
    let fetcher = HttpSkanConfigFetcher(
      endpoint: "https://ingest.test", apiKey: "apk_live_x")
    let request = fetcher.buildRequest(etag: nil)

    XCTAssertEqual(
      request.url?.absoluteString, "https://ingest.test/v1/sdk-config?platform=ios")
  }

  func testChallengeFetchRequestNamesThePlatform() {
    let fetcher = HttpChallengeFetcher(
      endpoint: "https://ingest.test", apiKey: "apk_live_x")
    let request = fetcher.buildRequest(deviceId: "dev 1")

    XCTAssertEqual(
      request.url?.absoluteString,
      "https://ingest.test/v1/attest/challenge?deviceId=dev%201&platform=ios")
  }
}

import Foundation
import XCTest

@testable import AdvenueCore

private enum Step: Sendable {
  case pending
  case resolved(String)
  case failure(Int)
}

private actor ScriptedFetcher: ConversionFetcher {
  private let steps: [Step]
  private(set) var calls = 0

  init(_ steps: [Step]) { self.steps = steps }

  func fetch() async throws -> ConversionResult {
    let step = calls < steps.count ? steps[calls] : .pending
    calls += 1
    switch step {
    case .pending: return .pending
    case .resolved(let value): return .resolved(DeepLink(deepLinkValue: value))
    case .failure(let status): throw IngestError(status: status)
    }
  }
}

final class ConversionTests: XCTestCase {
  func testPendingIsRetriedUntilItResolves() async {
    let fetcher = ScriptedFetcher([.pending, .pending, .resolved("promo/42")])
    let link = await resolveDeferredDeepLink(fetcher: fetcher, sleep: { _ in })
    XCTAssertEqual(link?.deepLinkValue, "promo/42")
    let calls = await fetcher.calls
    XCTAssertEqual(calls, 3)
  }

  /// Organic installs are never attributed, so most devices answer pending
  /// forever. The loop must give up rather than poll on a device that will
  /// never have an answer.
  func testAnInstallThatNeverResolvesGivesUp() async {
    let fetcher = ScriptedFetcher(Array(repeating: .pending, count: 10))
    let link = await resolveDeferredDeepLink(fetcher: fetcher, sleep: { _ in })
    XCTAssertNil(link)
    let calls = await fetcher.calls
    XCTAssertEqual(calls, 5)
  }

  /// A 4xx is the server saying "never". Retrying it is pure battery cost.
  func testNonRetryableStopsImmediately() async {
    let fetcher = ScriptedFetcher([.failure(403)])
    let link = await resolveDeferredDeepLink(fetcher: fetcher, sleep: { _ in })
    XCTAssertNil(link)
    let calls = await fetcher.calls
    XCTAssertEqual(calls, 1)
  }

  /// A 5xx is indistinguishable from pending, so it gets the same treatment.
  func testTransientFailureIsRetried() async {
    let fetcher = ScriptedFetcher([.failure(500), .resolved("promo/7")])
    let link = await resolveDeferredDeepLink(fetcher: fetcher, sleep: { _ in })
    XCTAssertEqual(link?.deepLinkValue, "promo/7")
  }

  func testBackoffScheduleMatchesSdkCore() async {
    let slept = Locked<[Int]>([])
    _ = await resolveDeferredDeepLink(
      fetcher: ScriptedFetcher(Array(repeating: .pending, count: 10)),
      sleep: { ms in slept.mutate { $0.append(ms) } })
    XCTAssertEqual(slept.value, [500, 1000, 2000, 4000])
  }

  func testAResolvedLinkIsMarkedDeferredAndFirstLaunch() async {
    let link = await resolveDeferredDeepLink(
      fetcher: ScriptedFetcher([.resolved("x")]), sleep: { _ in })
    XCTAssertEqual(link?.isDeferred, true)
    XCTAssertEqual(link?.isFirstLaunch, true)
  }
}

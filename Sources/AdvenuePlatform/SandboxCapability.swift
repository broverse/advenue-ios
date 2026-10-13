import AdvenueCore
import Foundation

/// Spec 2 §7.2 (P3): before its first upload a sandbox SDK asks the server
/// once per process whether it understands `environment`. A server without
/// the capability would file sandbox events as production.
public actor SandboxCapability {
  public typealias Probe = @Sendable () async throws -> (Int, Data)

  private let probe: Probe
  private var verdict: Bool?

  public init(probe: @escaping Probe) { self.probe = probe }

  public static func http(endpoint: String, session: URLSession = .shared) -> SandboxCapability {
    SandboxCapability(probe: {
      var request = URLRequest(url: URL(string: "\(endpoint)/health")!)
      request.httpMethod = "GET"
      request.timeoutInterval = 15
      let (data, response) = try await session.data(for: request)
      return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    })
  }

  /// Whether the server advertises sandbox. Throws a retryable `IngestError`
  /// when the answer is unknown (no response, a 5xx): that is not proof of an
  /// old server, so it is asked again on the next flush. A definite answer is
  /// kept for the life of the process.
  public func check() async throws -> Bool {
    if let verdict { return verdict }
    let status: Int
    let body: Data
    do {
      (status, body) = try await probe()
    } catch {
      throw IngestError(status: 408, networkCause: describeNetworkFailure(error))
    }
    if status == 0 || status >= 500 { throw IngestError(status: status == 0 ? 408 : status) }
    let supported = (200..<300).contains(status) && healthAdvertisesSandbox(body)
    verdict = supported
    return supported
  }
}

/// `GET /health` lists `sandbox` among its `capabilities`.
public func healthAdvertisesSandbox(_ body: Data) -> Bool {
  guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
    let capabilities = json["capabilities"] as? [Any]
  else { return false }
  return capabilities.contains { ($0 as? String) == "sandbox" }
}

import Foundation
import Testing
@testable import TubeTrackUK

@Suite(.serialized)
struct TfLClientRateLimitTests {
    @Test func rollingBudgetRejectsRequestsBeforeTheyReachTfL() async throws {
        let client = makeClient(
            limits: TfLRequestLimits(
                maximumRequestsPerMinute: 3,
                backgroundRequestsPerMinute: 2
            )
        )

        for index in 0 ..< 3 {
            let _: [Int] = try await client.get("/budget/\(index)")
        }

        await #expect(throws: TfLClientError.self) {
            let _: [Int] = try await client.get("/budget/rejected")
        }
        let diagnostics = await client.diagnostics()
        #expect(diagnostics.startedRequests == 3)
        #expect(diagnostics.budgetRejections == 1)
        #expect(TfLClientTestURLProtocol.requestCount == 3)
    }

    @Test func backgroundWorkLeavesCapacityForForegroundRequests() async throws {
        let client = makeClient(
            limits: TfLRequestLimits(
                maximumRequestsPerMinute: 3,
                backgroundRequestsPerMinute: 2
            )
        )

        for index in 0 ..< 2 {
            let _: [Int] = try await client.get(
                "/background/\(index)",
                priority: .background
            )
        }
        await #expect(throws: TfLClientError.self) {
            let _: [Int] = try await client.get(
                "/background/rejected",
                priority: .background
            )
        }
        let _: [Int] = try await client.get("/foreground/reserved")

        #expect(TfLClientTestURLProtocol.requestCount == 3)
    }

    @Test func identicalConcurrentRequestsShareOneNetworkTask() async throws {
        TfLClientTestURLProtocol.prepare(delay: 0.05)
        let client = makeClient(prepareProtocol: false)

        async let first: [Int] = client.get("/coalesced")
        async let second: [Int] = client.get("/coalesced")
        let values = try await (first, second)

        #expect(values.0.isEmpty)
        #expect(values.1.isEmpty)
        #expect(TfLClientTestURLProtocol.requestCount == 1)
        #expect(await client.diagnostics().coalescedRequests == 1)
    }

    @Test func rateLimitResponseStartsCooldownAndNeverExposesTheStatusCode() async throws {
        TfLClientTestURLProtocol.prepare(statusCode: 429, retryAfter: "120")
        let client = makeClient(prepareProtocol: false)

        do {
            let _: [Int] = try await client.get("/limited")
            Issue.record("Expected the request to be rate limited")
        } catch {
            #expect(!error.localizedDescription.contains("429"))
            #expect(error.localizedDescription == "Live data is temporarily unavailable.")
        }

        await #expect(throws: TfLClientError.self) {
            let _: [Int] = try await client.get("/blocked-during-cooldown")
        }
        let diagnostics = await client.diagnostics()
        #expect(diagnostics.startedRequests == 1)
        #expect(diagnostics.rateLimitedResponses == 1)
        #expect(diagnostics.budgetRejections == 1)
        #expect(TfLClientTestURLProtocol.requestCount == 1)
    }

    private func makeClient(
        limits: TfLRequestLimits = .app,
        prepareProtocol: Bool = true
    ) -> TfLClient {
        if prepareProtocol {
            TfLClientTestURLProtocol.prepare()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TfLClientTestURLProtocol.self]
        configuration.urlCache = nil
        return TfLClient(
            configuration: TfLConfiguration(
                baseURL: URL(string: "https://example.test")!,
                apiKey: nil
            ),
            session: URLSession(configuration: configuration),
            limits: limits
        )
    }
}

private final class TfLClientTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var configuredStatusCode = 200
    nonisolated(unsafe) private static var configuredRetryAfter: String?
    nonisolated(unsafe) private static var configuredDelay: TimeInterval = 0
    nonisolated(unsafe) private static var requests = 0
    private static let lock = NSLock()

    static var requestCount: Int {
        lock.withLock { requests }
    }

    static func prepare(
        statusCode: Int = 200,
        retryAfter: String? = nil,
        delay: TimeInterval = 0
    ) {
        lock.withLock {
            configuredStatusCode = statusCode
            configuredRetryAfter = retryAfter
            configuredDelay = delay
            requests = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let configuration = Self.lock.withLock { () -> (Int, String?, TimeInterval) in
            Self.requests += 1
            return (
                Self.configuredStatusCode,
                Self.configuredRetryAfter,
                Self.configuredDelay
            )
        }
        if configuration.2 > 0 {
            Thread.sleep(forTimeInterval: configuration.2)
        }
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var headers = ["Content-Type": "application/json"]
        if let retryAfter = configuration.1 {
            headers["Retry-After"] = retryAfter
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: configuration.0,
            httpVersion: nil,
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

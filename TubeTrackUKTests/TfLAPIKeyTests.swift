import Foundation
import Testing
@testable import TubeTrackUK

@Suite(.serialized)
struct TfLAPIKeyTests {
    @Test func clientUsesOnlyTheCurrentAppKeyQueryParameter() async throws {
        let client = makeClient()

        let _: [Int] = try await client.get(
            "/without-key",
            queryItems: [URLQueryItem(name: "detail", value: "true")]
        )
        var components = try #require(TfLAPIKeyURLProtocol.lastURL)
        #expect(components.queryItems?["detail"] == "true")
        #expect(components.queryItems?["app_key"] == nil)
        #expect(components.queryItems?["app_id"] == nil)

        await client.setAPIKey("  user key  ")
        let _: [Int] = try await client.get("/with-key")
        components = try #require(TfLAPIKeyURLProtocol.lastURL)
        #expect(components.queryItems?["app_key"] == "user key")
        #expect(components.queryItems?["app_id"] == nil)
    }

    @Test @MainActor func appStateNormalizesAndPersistsAUserKey() async throws {
        let store = InMemoryTfLAPIKeyStore()
        let state = TubeAppState(apiKeyStore: store)

        try await state.saveTfLAPIKey("  test-key  ")

        #expect(state.isTfLAPIKeyConfigured)
        #expect(state.hasUserProvidedTfLAPIKey)
        #expect(await store.load() == "test-key")

        try await state.removeTfLAPIKey()

        #expect(!state.hasUserProvidedTfLAPIKey)
        #expect(await store.load() == nil)
    }

    @Test func addingAKeyRaisesTheClientsLocalRequestBudget() async throws {
        let client = makeClient(
            limits: TfLRequestLimits(
                maximumRequestsPerMinute: 1,
                backgroundRequestsPerMinute: 1,
                authenticatedMaximumRequestsPerMinute: 3,
                authenticatedBackgroundRequestsPerMinute: 2
            )
        )

        let _: [Int] = try await client.get("/anonymous")
        await #expect(throws: TfLClientError.self) {
            let _: [Int] = try await client.get("/anonymous-over-budget")
        }

        await client.setAPIKey("key")
        let _: [Int] = try await client.get("/authenticated/one")
        let _: [Int] = try await client.get("/authenticated/two")
        await #expect(throws: TfLClientError.self) {
            let _: [Int] = try await client.get("/authenticated-over-budget")
        }
    }

    private func makeClient(limits: TfLRequestLimits = .app) -> TfLClient {
        TfLAPIKeyURLProtocol.prepare()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [TfLAPIKeyURLProtocol.self]
        sessionConfiguration.urlCache = nil
        return TfLClient(
            configuration: TfLConfiguration(
                baseURL: URL(string: "https://example.test")!,
                apiKey: nil
            ),
            session: URLSession(configuration: sessionConfiguration),
            limits: limits
        )
    }
}

private actor InMemoryTfLAPIKeyStore: TfLAPIKeyStoring {
    private var apiKey: String?

    func load() -> String? {
        apiKey
    }

    func save(_ apiKey: String?) {
        self.apiKey = apiKey
    }
}

private final class TfLAPIKeyURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var capturedURL: URL?
    private static let lock = NSLock()

    static var lastURL: URLComponents? {
        lock.withLock {
            capturedURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        }
    }

    static func prepare() {
        lock.withLock {
            capturedURL = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.withLock {
            Self.capturedURL = url
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
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

private extension Array where Element == URLQueryItem {
    subscript(name: String) -> String? {
        first { $0.name == name }?.value
    }
}

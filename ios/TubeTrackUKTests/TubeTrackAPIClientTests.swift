import Foundation
import Testing
@testable import TubeTrackUK

@Suite(.serialized)
struct TubeTrackAPIClientTests {
    @Test func decodesTheServerEnvelopeWithoutAddingCredentials() async throws {
        APIClientURLProtocol.prepare(
            body: Data(#"{"data":[1,2,3],"meta":{"cached":true}}"#.utf8)
        )
        let client = makeClient()

        let values: [Int] = try await client.get(
            "/api/v1/example",
            queryItems: [URLQueryItem(name: "lineIds", value: "victoria")]
        )

        #expect(values == [1, 2, 3])
        let components = try #require(APIClientURLProtocol.lastURL)
        #expect(components.path == "/api/v1/example")
        #expect(components.queryItems?["lineIds"] == "victoria")
        #expect(components.queryItems?["app_key"] == nil)
        #expect(components.host == "api.test")
    }

    @Test func rateLimitResponseUsesPassengerSafeCopy() async throws {
        APIClientURLProtocol.prepare(
            statusCode: 429,
            retryAfter: "120",
            body: Data(#"{"error":{"code":"RATE_LIMITED"}}"#.utf8)
        )
        let client = makeClient()

        do {
            let _: [Int] = try await client.get("/api/v1/live")
            Issue.record("Expected the request to be rate limited")
        } catch let error as TubeTrackAPIClientError {
            #expect(error.localizedDescription == "Live data is temporarily unavailable.")
            if case let .rateLimited(retryAfter) = error {
                #expect(try #require(retryAfter) > Date.now)
            } else {
                Issue.record("Expected a rate-limit error")
            }
        }
    }

    @Test func directTfLFieldNamesAreNotRequiredForNormalisedArrivals() async throws {
        let body = Data(#"{"data":[{"id":"one","lineId":"victoria","stopId":"940GZZLUVIC","destinationStopId":"940GZZLUBXN"}]}"#.utf8)
        APIClientURLProtocol.prepare(body: body)
        let client = makeClient()

        let arrivals: [TfLArrivalPrediction] = try await client.get("/api/v1/arrivals/940GZZLUVIC")

        #expect(arrivals.first?.naptanId == "940GZZLUVIC")
        #expect(arrivals.first?.destinationNaptanId == "940GZZLUBXN")
    }

    @Test func snapshotPreservesTheServersTimestampAndStaleFlag() async throws {
        APIClientURLProtocol.prepare(body: Data(
            #"{"data":[1,2,3],"meta":{"updatedAt":"2023-11-14T22:13:20.000Z","cached":true,"stale":true}}"#.utf8
        ))

        let snapshot: TubeTrackAPIResponse<[Int]> = try await makeClient().getSnapshot("/api/v1/status")

        #expect(snapshot.data == [1, 2, 3])
        #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(snapshot.cached)
        #expect(snapshot.stale)
    }

    @Test func metadataFreeResponsesUseTheReceiptTime() async throws {
        for fixture in [#"{"data":[1,2,3]}"#, "[1,2,3]"] {
            APIClientURLProtocol.prepare(body: Data(fixture.utf8))
            let before = Date.now

            let snapshot: TubeTrackAPIResponse<[Int]> = try await makeClient().getSnapshot("/api/v1/status")

            #expect(snapshot.data == [1, 2, 3])
            #expect(snapshot.updatedAt >= before)
            #expect(snapshot.updatedAt <= Date.now)
            #expect(!snapshot.cached)
            #expect(!snapshot.stale)
        }
    }

    @Test func journeyValidationErrorsPreservePassengerSafeMessages() async throws {
        APIClientURLProtocol.prepare(statusCode: 422, body: Data(
            #"{"error":{"code":"UNKNOWN_STATION","message":"Choose a station from the London rail catalogue."}}"#.utf8
        ))
        do {
            let _: JourneyPlan = try await makeClient().get("/api/v1/journeys")
            Issue.record("Expected the journey to be rejected")
        } catch let error as TubeTrackAPIClientError {
            if case let .serviceError(code, message) = error {
                #expect(code == "UNKNOWN_STATION")
                #expect(message == "Choose a station from the London rail catalogue.")
            } else {
                Issue.record("Expected a structured journey error")
            }
        }
    }

    private func makeClient() -> TubeTrackAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientURLProtocol.self]
        configuration.urlCache = nil
        return TubeTrackAPIClient(
            configuration: TubeTrackAPIConfiguration(
                baseURL: URL(string: "https://api.test")!
            ),
            session: URLSession(configuration: configuration)
        )
    }
}

private final class APIClientURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var capturedURL: URL?
    nonisolated(unsafe) private static var configuredStatusCode = 200
    nonisolated(unsafe) private static var configuredRetryAfter: String?
    nonisolated(unsafe) private static var configuredBody = Data()
    private static let lock = NSLock()

    static var lastURL: URLComponents? {
        lock.withLock {
            capturedURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        }
    }

    static func prepare(
        statusCode: Int = 200,
        retryAfter: String? = nil,
        body: Data
    ) {
        lock.withLock {
            capturedURL = nil
            configuredStatusCode = statusCode
            configuredRetryAfter = retryAfter
            configuredBody = body
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let values = Self.lock.withLock { () -> (Int, String?, Data) in
            Self.capturedURL = url
            return (Self.configuredStatusCode, Self.configuredRetryAfter, Self.configuredBody)
        }
        var headers = ["Content-Type": "application/json"]
        if let retryAfter = values.1 {
            headers["Retry-After"] = retryAfter
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: values.0,
            httpVersion: nil,
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: values.2)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Array where Element == URLQueryItem {
    subscript(name: String) -> String? {
        first { $0.name == name }?.value
    }
}

import Foundation
import Testing
import TubeTrackCore
@testable import TubeTrackUK

/// The client half of the push registration contract.
///
/// The server half is `api/tube-track-api/lib/push-routes.js`, whose validation
/// these assertions mirror field for field — a rename on either side silently
/// turns every registration into a 400, and nothing else in either codebase
/// would notice.
///
/// Serialized because the URLProtocol stub below captures into static state,
/// which parallel tests would trample.
@Suite(.serialized)
struct LiveActivityPushRegistrarTests {
    private func attributes(
        direction: DepartureDirectionFilter = .eastbound
    ) -> DepartureActivityAttributes {
        DepartureActivityAttributes(
            activityID: "DEADBEEF-1234-5678",
            stationHubID: "940GZZLUOXC",
            stationName: "Oxford Circus",
            lineID: .central,
            direction: direction.displayName,
            directionFilter: direction,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            hardEndsAt: Date(timeIntervalSince1970: 1_800_005_400)
        )
    }

    private func registrar(secret: String = "a-shared-client-secret") -> LiveActivityPushRegistrar {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegistrationURLProtocol.self]
        return LiveActivityPushRegistrar(
            baseURL: URL(string: "https://api.example.test/tube-track")!,
            clientSecret: secret,
            installID: "install-0123456789",
            session: URLSession(configuration: configuration)
        )
    }

    @Test func registrationSendsExactlyWhatTheServerValidates() async throws {
        RegistrationURLProtocol.prepare(statusCode: 201)
        try await registrar().register(
            token: String(repeating: "ab", count: 32),
            attributes: attributes(),
            frequentPushesEnabled: true
        )

        let request = try #require(RegistrationURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/tube-track/api/v1/push/live-activities")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a-shared-client-secret")
        #expect(request.value(forHTTPHeaderField: "X-TubeTrack-Install") == "install-0123456789")

        let body = try #require(RegistrationURLProtocol.lastBody)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["activityId"] as? String == "DEADBEEF-1234-5678")
        #expect(json["token"] as? String == String(repeating: "ab", count: 32))
        #expect(json["lineId"] as? String == "central")
        // The canonical filter, never the display label — the server filters by
        // this and would otherwise reject "Eastbound".
        #expect(json["direction"] as? String == "eastbound")
        #expect(json["hubId"] as? String == "940GZZLUOXC")
        #expect(json["frequentPushesEnabled"] as? Bool == true)

        let stopIDs = try #require(json["stopIds"] as? [String])
        #expect(!stopIDs.isEmpty)
        // The server checks these against its own station data, so they have to
        // be real stop points rather than the hub id when the two differ.
        #expect(stopIDs.allSatisfy { !$0.isEmpty })
    }

    @Test("A direction the station does not label resolves to any, which the server accepts")
    func unlabelledDirectionsTravelAsAny() async throws {
        RegistrationURLProtocol.prepare(statusCode: 201)
        try await registrar().register(
            token: String(repeating: "ab", count: 32),
            attributes: attributes(direction: .any),
            frequentPushesEnabled: false
        )

        let body = try #require(RegistrationURLProtocol.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["direction"] as? String == "any")
        #expect(json["frequentPushesEnabled"] as? Bool == false)
    }

    @Test("A build with no secret never registers rather than sending an empty key")
    func anUnconfiguredBuildStaysQuiet() async throws {
        RegistrationURLProtocol.prepare(statusCode: 201)
        let subject = registrar(secret: "")
        #expect(subject.isConfigured == false)

        try await subject.register(
            token: String(repeating: "ab", count: 32),
            attributes: attributes(),
            frequentPushesEnabled: true
        )
        #expect(RegistrationURLProtocol.lastRequest == nil)
    }

    @Test func aRefusedRegistrationSurfacesAsAnErrorRatherThanSilentSuccess() async {
        RegistrationURLProtocol.prepare(statusCode: 401)
        await #expect(throws: (any Error).self) {
            try await registrar().register(
                token: String(repeating: "ab", count: 32),
                attributes: attributes(),
                frequentPushesEnabled: true
            )
        }
    }

    @Test func unregisteringAddressesTheActivityAndNeverThrows() async {
        RegistrationURLProtocol.prepare(statusCode: 204)
        await registrar().unregister(activityID: "DEADBEEF-1234-5678")

        let request = RegistrationURLProtocol.lastRequest
        #expect(request?.httpMethod == "DELETE")
        #expect(
            request?.url?.path == "/tube-track/api/v1/push/live-activities/DEADBEEF-1234-5678"
        )

        // A server that is simply down must not turn into an error the
        // passenger sees while stopping tracking.
        RegistrationURLProtocol.prepare(statusCode: 500)
        await registrar().unregister(activityID: "DEADBEEF-1234-5678")
    }

    @Test("The install id is stable, so subscriptions are not orphaned on relaunch")
    func theInstallIdentifierIsStable() {
        #expect(AppInstall.identifier == AppInstall.identifier)
        // The server accepts [0-9A-Za-z-]{8,64}.
        let identifier = AppInstall.identifier
        #expect(identifier.count >= 8 && identifier.count <= 64)
        #expect(identifier.allSatisfy { $0.isHexDigit || $0.isLetter || $0.isNumber || $0 == "-" })
    }
}

private final class RegistrationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var capturedRequest: URLRequest?
    nonisolated(unsafe) private static var capturedBody: Data?
    nonisolated(unsafe) private static var statusCode = 200
    private static let lock = NSLock()

    static var lastRequest: URLRequest? { lock.withLock { capturedRequest } }
    static var lastBody: Data? { lock.withLock { capturedBody } }

    static func prepare(statusCode: Int) {
        lock.withLock {
            capturedRequest = nil
            capturedBody = nil
            self.statusCode = statusCode
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol strips httpBody into a stream, so read it back out.
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer[0..<read])
            }
            return data
        }

        let status = Self.lock.withLock { () -> Int in
            Self.capturedRequest = request
            Self.capturedBody = body
            return Self.statusCode
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

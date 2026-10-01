import Foundation
import Testing
import TubeTrackCore
@testable import TubeTrackUK

@Suite(.serialized) @MainActor
struct ScheduledJourneyStoreTests {
    private func journey() -> ScheduledJourney {
        ScheduledJourney(id: "journey-0001", name: "Office", enabled: false,
            morning: .init(startMinute: 480, endMinute: 600,
                board: ScheduledBoard(hub: StationHub(id: "940GZZLUOXC", name: "Oxford Circus",
                    stopIDs: ["940GZZLUOXC"], lineIDs: [.central]), line: .central, direction: .eastbound)))
    }

    private func withStore(initial: [ScheduledJourney] = [], _ run: @MainActor (ScheduledJourneyStore, UserDefaults) async throws -> Void) async throws {
        let suite = "ScheduleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try payload(initial), forKey: "scheduledJourneys.cache.\(AppInstall.identifier)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScheduleURLProtocol.self]
        let store = ScheduledJourneyStore(defaults: defaults, session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://schedules.example.test")!, pushToken: "test-token", observesTokens: false)
        try await run(store, defaults)
    }

    private func payload(_ journeys: [ScheduledJourney]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "journeys": journeys.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
            "revision": 1, "maximumJourneys": 3
        ])
    }

    @Test func replacementKeepsUnrelatedJourneysAndFailedWritePreservesOriginals() async throws {
        var original = journey()
        original.enabled = true
        var draft = original
        draft.id = "new-journey"
        draft.name = "New commute"
        var unrelated = original
        unrelated.id = "weekend-journey"
        unrelated.days = [6, 7]
        try await withStore(initial: [original, unrelated]) { store, _ in
            ScheduleURLProtocol.respond(status: 200, data: try payload([draft, unrelated]))
            try await store.save(draft, replacing: [original])
            #expect(store.journeys == [draft, unrelated])
            #expect(ScheduleURLProtocol.lastRequest?.url?.path == "/api/v1/scheduled-journeys")
            let body = try #require(ScheduleURLProtocol.lastBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let submitted = try #require(object["journeys"] as? [[String: Any]])
            #expect(Set(submitted.compactMap { $0["id"] as? String }) == Set([draft.id, unrelated.id]))
            #expect(object["revision"] as? Int == 1)
        }
        try await withStore(initial: [original, unrelated]) { store, _ in
            ScheduleURLProtocol.respond(status: 503, data: Data(#"{"error":{"message":"Try again"}}"#.utf8))
            await #expect(throws: ScheduleError.self) { try await store.save(draft, replacing: [original]) }
            #expect(store.journeys == [original, unrelated])
            #expect(ScheduleURLProtocol.lastRequest?.url?.path == "/api/v1/scheduled-journeys")
        }
    }

    @Test func replacementRejectsChangedConfirmationWithoutWriting() async throws {
        var original = journey()
        original.enabled = true
        var changed = original
        changed.name = "Changed since confirmation"
        var draft = original
        draft.id = "new-journey"
        try await withStore(initial: [changed]) { store, _ in
            ScheduleURLProtocol.respond(status: 200, data: try payload([draft]))
            await #expect(throws: ScheduleError.self) { try await store.save(draft, replacing: [original]) }
            #expect(ScheduleURLProtocol.lastRequest == nil)
            #expect(store.journeys == [changed])
        }
    }

    @Test func failedSavesLeaveTheConfirmedLocalCopyUnchanged() async throws {
        try await withStore { store, _ in
            ScheduleURLProtocol.respond(status: 503, data: Data(#"{"error":{"message":"Try again"}}"#.utf8))
            await #expect(throws: ScheduleError.self) { try await store.save(journey()) }
            #expect(store.journeys.isEmpty)
            #expect(!store.isSaving)
        }
    }

    @Test func confirmedSavesPersistAndCarryInstallationOwnership() async throws {
        try await withStore { store, defaults in
            let journey = journey()
            let payload = try JSONSerialization.data(withJSONObject: [
                "journeys": [JSONSerialization.jsonObject(with: JSONEncoder().encode(journey))],
                "revision": 1, "maximumJourneys": 3
            ])
            ScheduleURLProtocol.respond(status: 200, data: payload)
            try await store.save(journey)
            #expect(store.journeys == [journey])
            let request = try #require(ScheduleURLProtocol.lastRequest)
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.path == "/api/v1/scheduled-journeys")
            #expect(request.value(forHTTPHeaderField: "X-TubeTrack-Install") == AppInstall.identifier)
            #expect(request.value(forHTTPHeaderField: "X-TubeTrack-Schedule-Key")?.count == 64)
            let reloaded = ScheduledJourneyStore(defaults: defaults, observesTokens: false)
            #expect(reloaded.journeys == [journey])
        }
    }

    @Test func deletingDoesNotRequireLiveActivityPermissionOrAPNsSetup() async throws {
        try await withStore { store, _ in
            let payload = try JSONSerialization.data(withJSONObject: [
                "journeys": [JSONSerialization.jsonObject(with: JSONEncoder().encode(journey()))],
                "revision": 1, "maximumJourneys": 3
            ])
            ScheduleURLProtocol.respond(status: 200, data: payload)
            try await store.save(journey())
            ScheduleURLProtocol.respond(status: 200, data: Data(#"{"journeys":[],"revision":2,"maximumJourneys":3}"#.utf8))
            try await store.delete(journey())
            #expect(store.journeys.isEmpty)
        }
    }
}

private final class ScheduleURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var data = Data()
    nonisolated(unsafe) private static var request: URLRequest?
    nonisolated(unsafe) private static var body: Data?
    private static let lock = NSLock()
    static var lastRequest: URLRequest? { lock.withLock { request } }
    static var lastBody: Data? { lock.withLock { body } }
    static func respond(status: Int, data: Data) {
        lock.withLock { self.status = status; self.data = data; request = nil; body = nil }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            var data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            body = data
        }
        let (status, data) = Self.lock.withLock {
            Self.request = request
            Self.body = body
            return request.url?.lastPathComponent == "device"
                ? (200, Data("{}".utf8)) : (Self.status, Self.data)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

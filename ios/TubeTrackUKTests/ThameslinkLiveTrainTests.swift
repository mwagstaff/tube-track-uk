import Foundation
import Testing
@testable import TubeTrackUK
import TubeTrackCore

/// Serialized because the URLProtocol stub below records into static state.
@Suite(.serialized)
struct ThameslinkLiveTrainTests {
    private func service() throws -> TubeTrainService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThameslinkTrainsURLProtocol.self]
        configuration.urlCache = nil
        let client = TubeTrackAPIClient(
            configuration: TubeTrackAPIConfiguration(baseURL: URL(string: "https://trains.test")!),
            session: URLSession(configuration: configuration)
        )
        return TubeTrainService(client: client, repository: TubeNetworkRepository(graph: try TubeGraph.bundled()))
    }

    @Test func thameslinkTrainsComeFromTheBoardEstimatesNotTheBulkFeed() async throws {
        ThameslinkTrainsURLProtocol.prepare(Data("""
        {"data":[
          {"id":"tl-1","lineId":"thameslink","destination":"Bedford","destinationStopId":"910GBEDFDM",
           "nextStopId":"910GWHMPSTM","expectedArrival":"2026-09-28T08:30:00Z",
           "previousStationId":"910GKNTSHTN","nextStationId":"910GWHMPSTM","progress":0.4,"secondsToNextStation":90},
          {"id":"tl-2","lineId":"thameslink","destination":"Brighton","destinationStopId":"910GBRGHTN",
           "nextStopId":"910GSTPXBOX","expectedArrival":"2026-09-28T08:33:00Z",
           "previousStationId":"910GWHMPSTM","nextStationId":"910GKNTSHTN","progress":0.5,"secondsToNextStation":120},
          {"id":"tl-3","lineId":"thameslink","destination":"Nowhere","nextStopId":"X","expectedArrival":null,
           "previousStationId":"910GKNTSHTN","nextStationId":"910GELTR","progress":0.5,"secondsToNextStation":60}
        ],"meta":{"updatedAt":"2026-09-28T08:28:00Z","cached":false,"stale":false}}
        """.utf8))

        let trains = try await service().fetch(lineIDs: [.thameslink])

        #expect(ThameslinkTrainsURLProtocol.requestedPaths == ["/api/v1/thameslink/trains"])
        // The third estimate names track the app does not have, so it is dropped.
        #expect(trains.map(\.id) == ["tl-1", "tl-2"])
        let calling = try #require(trains.first { $0.id == "tl-1" })
        #expect(calling.segmentID == "thameslink:910GKNTSHTN:910GWHMPSTM")
        #expect(calling.callingStationID == "910GWHMPSTM")
        #expect(calling.updatedAt == ISO8601DateFormatter().date(from: "2026-09-28T08:28:00Z"))
        // The Brighton train runs through Kentish Town without stopping: its
        // callout names St Pancras, where it next calls.
        let fast = try #require(trains.first { $0.id == "tl-2" })
        #expect(fast.nextStationID == "910GKNTSHTN")
        #expect(fast.callingStationID == "910GSTPXBOX")
        #expect(fast.secondsToNextStop(at: ISO8601DateFormatter().date(from: "2026-09-28T08:31:00Z")!) == 120)
    }

    @Test func aThameslinkFailureNeverHidesOtherLinesTrains() async throws {
        ThameslinkTrainsURLProtocol.prepare(nil)
        let trains = try await service().fetch(lineIDs: [.thameslink, .victoria])
        #expect(trains.isEmpty)
        #expect(Set(ThameslinkTrainsURLProtocol.requestedPaths) == ["/api/v1/thameslink/trains", "/api/v1/live"])
    }
}

private final class ThameslinkTrainsURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var thameslinkResponse: Data?
    nonisolated(unsafe) static var requestedPaths: [String] = []
    private static let lock = NSLock()

    static func prepare(_ response: Data?) {
        lock.withLock {
            thameslinkResponse = response
            requestedPaths = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let path = url.path.replacingOccurrences(of: "/tube-track", with: "")
        let body: Data? = Self.lock.withLock {
            Self.requestedPaths.append(path)
            if path == "/api/v1/thameslink/trains" { return Self.thameslinkResponse }
            return Data("[]".utf8)
        }
        let status = body == nil ? 503 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body ?? Data())
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

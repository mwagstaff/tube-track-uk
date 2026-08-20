import Foundation
import Testing
@testable import TubeTrackUK

struct PerformanceRegressionTests {
    @Test func lightweightLivePredictionIgnoresUnusedDatePayload() throws {
        let json = """
        [{
          "id": "prediction-id",
          "vehicleId": "train-42",
          "lineId": "victoria",
          "naptanId": "940GZZLUVIC",
          "direction": "southbound",
          "destinationName": "Brixton",
          "destinationNaptanId": "940GZZLUBXN",
          "towards": "Brixton",
          "expectedArrival": "intentionally-not-a-date",
          "timeToStation": 75,
          "currentLocation": "Between stations",
          "stationName": "Unused station name",
          "platformName": "Unused platform"
        }]
        """

        let predictions = try JSONDecoder.tfl.decode(
            [TfLLiveTrainPrediction].self,
            from: Data(json.utf8)
        )

        let prediction = try #require(predictions.first)
        #expect(prediction.vehicleId == "train-42")
        #expect(prediction.lineId == TubeLineID.victoria.rawValue)
        #expect(prediction.timeToStation == 75)
    }

    @Test func indexedSegmentLookupMatchesEveryBundledConnectionInBothDirections() throws {
        let graph = try TubeGraph.bundled()
        let repository = TubeNetworkRepository(graph: graph)

        for segment in graph.segments {
            #expect(repository.segment(
                between: segment.fromStationID,
                and: segment.toStationID,
                on: segment.lineID
            )?.id == segment.id)
            #expect(repository.segment(
                between: segment.toStationID,
                and: segment.fromStationID,
                on: segment.lineID
            )?.id == segment.id)
        }
    }

    @Test func cachedRenderPathInterpolatesWithoutRebuildingGeometry() throws {
        let from = TubeStation(
            id: "from",
            name: "From",
            latitude: 51,
            longitude: 0,
            schematicX: 0,
            schematicY: 0,
            lineIDs: [.central],
            interchange: false,
            searchAliases: [],
            hubID: nil
        )
        let to = TubeStation(
            id: "to",
            name: "To",
            latitude: 51,
            longitude: 0.02,
            schematicX: 1,
            schematicY: 0,
            lineIDs: [.central],
            interchange: false,
            searchAliases: [],
            hubID: nil
        )
        let segment = TubeSegment(
            id: "central:from:to",
            lineID: .central,
            fromStationID: from.id,
            toStationID: to.id,
            schematicPoints: [],
            geographicPoints: [
                GeographicPoint(latitude: 51, longitude: 0),
                GeographicPoint(latitude: 51, longitude: 0.01),
                GeographicPoint(latitude: 51, longitude: 0.02),
            ]
        )
        let path = RealWorldRenderPath(
            segment: segment,
            stationsByID: [from.id: from, to.id: to]
        )

        let quarter = try #require(path.coordinate(at: 0.25))
        #expect(abs(quarter.latitude - 51) < 0.000_001)
        #expect(abs(quarter.longitude - 0.005) < 0.000_001)
        #expect(path.coordinate(at: -1)?.longitude == from.longitude)
        #expect(path.coordinate(at: 2)?.longitude == to.longitude)
    }
}

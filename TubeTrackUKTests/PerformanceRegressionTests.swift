import Foundation
import Testing
@testable import TubeTrackUK

struct PerformanceRegressionTests {
    @Test func defaultTfLSessionDoesNotRetainURLCacheData() {
        let configuration = TfLClient.defaultSessionConfiguration()

        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func allLiveTrainLinesAreSplitIntoDeterministicBoundedBatches() {
        let requestedLines = TubeTrainRequestBatcher.requestedLines(for: [])
        let batches = TubeTrainRequestBatcher.batches(from: requestedLines)

        #expect(requestedLines == requestedLines.sorted { $0.rawValue < $1.rawValue })
        #expect(!requestedLines.contains(.dlr))
        #expect(batches.allSatisfy { !$0.isEmpty && $0.count <= 3 })
        #expect(batches.flatMap { $0 } == requestedLines)
        #expect(batches == [
            [.bakerloo, .central, .circle],
            [.district, .elizabeth, .hammersmithCity],
            [.jubilee, .liberty, .lioness],
            [.metropolitan, .mildmay, .northern],
            [.piccadilly, .suffragette, .victoria],
            [.waterlooCity, .weaver, .windrush],
        ])
    }

    @Test func explicitLiveTrainFilterIsSortedAndDropsUnsupportedLines() {
        let requestedLines = TubeTrainRequestBatcher.requestedLines(
            for: [.victoria, .dlr, .bakerloo, .central]
        )
        let batches = TubeTrainRequestBatcher.batches(from: requestedLines)

        #expect(requestedLines == [.bakerloo, .central, .victoria])
        #expect(batches == [[.bakerloo, .central, .victoria]])
        #expect(TubeTrainRequestBatcher.batches(from: []) == [])
    }

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

    @Test func realWorldMapBatchesSegmentsIntoStableNonBranchingPolylines() throws {
        let graph = try TubeGraph.bundled()
        let renderData = RealWorldMapRenderData(graph: graph)
        let renderedSegmentIDs = renderData.polylines.flatMap(\.segmentIDs)

        #expect(renderedSegmentIDs.count == graph.segments.count)
        #expect(Set(renderedSegmentIDs) == Set(graph.segments.map(\.id)))
        #expect(renderData.polylines.count < 100)
        #expect(renderData.polylines.allSatisfy { $0.coordinates.count >= 2 })

        let affectedSegmentIDs = Set(graph.segments.prefix(75).map(\.id))
        let affectedPolylines = renderData.polylines(covering: affectedSegmentIDs)
        #expect(Set(affectedPolylines.flatMap(\.segmentIDs)) == affectedSegmentIDs)
    }
}

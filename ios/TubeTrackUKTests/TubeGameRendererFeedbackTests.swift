import CoreGraphics
import Foundation
import Testing
@testable import TubeTrackUK

@Suite("Track-Man renderer feedback")
struct TubeGameRendererFeedbackTests {
    @Test func gamePreservesKenningtonsAuthoredBranchRoundelsAndConnector() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let network = try TubeGameNetwork(graph: graph, document: document)
        let model = TubeGameRenderModel(document: document, network: network)

        let marker = try #require(model.stationMarkers.first {
            $0.id == "940GZZLUKNG"
        })
        let circles = marker.primitives.compactMap { primitive -> BeckMapCirclePrimitive? in
            guard case let .circle(circle) = primitive else { return nil }
            return circle
        }
        let connectors = marker.primitives.compactMap { primitive -> BeckMapLinePrimitive? in
            guard case let .connector(connector) = primitive else { return nil }
            return connector
        }

        #expect(circles.count == 2)
        #expect(connectors.count == 1)
        #expect(Set(circles.map { CGPoint(x: $0.centre.x, y: $0.centre.y) }) == Set([
            CGPoint(x: connectors[0].start.x, y: connectors[0].start.y),
            CGPoint(x: connectors[0].end.x, y: connectors[0].end.y),
        ]))
        let destinations = Set(network.railConnections(fromHubID: marker.hubID).map(\.toStationID))
        #expect(destinations == [
            "940GZZLUEAC",
            "940GZZLUOVL",
            "940GZZLUWLO",
            "940GZZNEUGST",
        ])
    }

    @Test func everyRenderedConnectorBelongsToATraversableGameHub() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let network = try TubeGameNetwork(graph: graph, document: document)
        let model = TubeGameRenderModel(document: document, network: network)

        let connectedMarkers = model.stationMarkers.filter { marker in
            marker.primitives.contains { primitive in
                if case .connector = primitive { return true }
                if case .walkingConnector = primitive { return true }
                return false
            }
        }

        #expect(!connectedMarkers.isEmpty)
        for marker in connectedMarkers {
            #expect(
                network.railConnections(fromHubID: marker.hubID).count >= 2,
                "\(marker.id) renders a connector but its game hub has fewer than two rail choices"
            )
        }
    }

    @Test func stationLabelFadesAndDriftsForExactlyFourSeconds() {
        #expect(TubeGameStationLabelPresentation.isVisible(
            eatenAt: 10,
            currentTime: 10
        ))
        #expect(TubeGameStationLabelPresentation.opacity(
            eatenAt: 10,
            currentTime: 10
        ) == 1)
        #expect(TubeGameStationLabelPresentation.verticalOffset(
            eatenAt: 10,
            currentTime: 12,
            reduceMotion: false
        ) == -13)
        #expect(TubeGameStationLabelPresentation.opacity(
            eatenAt: 10,
            currentTime: 12
        ) == 0.5)
        #expect(TubeGameStationLabelPresentation.isVisible(
            eatenAt: 10,
            currentTime: 13.999
        ))
        #expect(!TubeGameStationLabelPresentation.isVisible(
            eatenAt: 10,
            currentTime: 14
        ))
        #expect(TubeGameStationLabelPresentation.opacity(
            eatenAt: 10,
            currentTime: 14
        ) == 0)
        #expect(TubeGameStationLabelPresentation.verticalOffset(
            eatenAt: 10,
            currentTime: 12,
            reduceMotion: true
        ) == 0)
    }

    @Test func stationLabelsPruneExpiredAndFutureEventsThenKeepOnlyNewest() {
        let currentTime: TimeInterval = 10
        var consumptions = (0 ..< 8).map { index in
            consumption(
                hubID: "hub-\(index)",
                eatenAt: 6.1 + Double(index) * 0.4
            )
        }
        consumptions.append(consumption(hubID: "expired", eatenAt: 6))
        consumptions.append(consumption(hubID: "future", eatenAt: 10.1))

        let visible = TubeGameStationLabelPresentation.visibleConsumptions(
            consumptions,
            at: currentTime
        )

        #expect(visible.map(\.hubID) == ["hub-7"])
    }

    @Test func routeGeometryFollowsThePreviewStationOrder() throws {
        let edge = TubeGameRenderModel.RouteEdge(
            id: "edge",
            fromStationID: "a",
            toStationID: "b",
            geometry: TubeGamePathGeometry(points: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 10, y: 0),
                CGPoint(x: 20, y: 0),
            ])
        )

        let forward = try #require(TubeGameRouteFeedback.orientedGeometry(
            for: edge,
            fromStationID: "a",
            toStationID: "b"
        ))
        let reverse = try #require(TubeGameRouteFeedback.orientedGeometry(
            for: edge,
            fromStationID: "b",
            toStationID: "a"
        ))

        #expect(forward.points.first == CGPoint(x: 0, y: 0))
        #expect(forward.points.last == CGPoint(x: 20, y: 0))
        #expect(reverse.points.first == CGPoint(x: 20, y: 0))
        #expect(reverse.points.last == CGPoint(x: 0, y: 0))
        #expect(TubeGameRouteFeedback.orientedGeometry(
            for: edge,
            fromStationID: "a",
            toStationID: "c"
        ) == nil)

        let forwardMarker = try #require(TubeGameRouteFeedback.markers(
            along: forward,
            spacing: 100,
            phase: 50
        ).first)
        let reverseMarker = try #require(TubeGameRouteFeedback.markers(
            along: reverse,
            spacing: 100,
            phase: 50
        ).first)
        #expect(forwardMarker.tangent == CGVector(dx: 1, dy: 0))
        #expect(reverseMarker.tangent == CGVector(dx: -1, dy: 0))
    }

    @Test func swipeHintsUseUniqueLineCodesAndPlainLanguageDirections() {
        let codes = TubeLineID.allCases.map(TubeGameSwipeHintPresentation.lineCode)

        #expect(Set(codes).count == TubeLineID.allCases.count)
        #expect(codes.allSatisfy { (2 ... 3).contains($0.count) })
        #expect(TubeGameSwipeHintPresentation.spokenName(for: .north) == "swipe up")
        #expect(
            TubeGameSwipeHintPresentation.spokenName(for: .southWest)
                == "swipe down and left"
        )
    }

    private func consumption(
        hubID: String,
        eatenAt: TimeInterval
    ) -> TubeGameStationConsumption {
        TubeGameStationConsumption(
            hubID: hubID,
            stationName: hubID,
            position: .zero,
            lineID: .central,
            pointsAwarded: 10,
            eatenAtElapsedTime: eatenAt
        )
    }

}

import Foundation
import Testing
@testable import TubeTrackUK

@MainActor
struct MapRoundelTapTests {
    @Test(arguments: [CGFloat(0.25), 0.5, 1, 3])
    func everyCombinedMapRoundelOpensItsStationAndService(scale: CGFloat) throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        let roundels = try #require(document.referenceArtwork?.stationRoundels)
        #expect(roundels.count == 374)
        for roundel in roundels {
            let station = try #require(graph.stationsByID[roundel.stationID])
            if let lineID = roundel.lineID {
                #expect(graph.lineIDs(at: station).contains(lineID), "Invalid service for \(station.name)")
            } else {
                #expect(roundel.operatorID?.hasPrefix("national-rail:") == true)
                #expect(!NationalRailStations.codes(for: [station.id]).isEmpty)
            }
            // Interior taps in each direction also check overlapping label
            // boxes and the closely spaced service circles at rail hubs.
            for delta in [CGPoint.zero, CGPoint(x: 2, y: 0), CGPoint(x: -2, y: 0),
                          CGPoint(x: 0, y: 2), CGPoint(x: 0, y: -2)] {
                let selection = try #require(resolve(
                    CGPoint(x: roundel.centre.x + delta.x, y: roundel.centre.y + delta.y),
                    scale: scale, document: document, graph: graph
                ))
                #expect(selection.stationID == station.id, "Wrong board at \(station.name): \(roundel.centre)")
                #expect(selection.preferredLineID == roundel.lineID)
                #expect(selection.preferredOperatorID == roundel.operatorID)
            }
        }
    }

    @Test(arguments: [CGFloat(0.25), 1, 3])
    func everyOriginalMapRoundelResolvesToItsStationHub(scale: CGFloat) throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let cache = BeckMapCanvas.RenderCache(document: document)
        for marker in document.stationMarkers {
            let station = try #require(graph.stationsByID[marker.stationID])
            let hubIDs = Set(graph.stations(inSamePlaceAs: station).map(\.id))
            for primitive in marker.primitives {
                guard case let .circle(circle) = primitive else { continue }
                let selection = try #require(resolve(CGPoint(x: circle.centre.x, y: circle.centre.y), scale: scale,
                    document: document, graph: graph, segments: cache.renderedSegments))
                #expect(hubIDs.contains(selection.stationID), "Wrong board at \(station.name): \(circle.centre)")
                #expect(selection.preferredLineID.map { graph.lineIDs(at: station).contains($0) } == true)
            }
        }
    }

    @Test(arguments: [CGFloat(0.5), 1, 3])
    func reviewedInterchangesSelectTheDrawnService(scale: CGFloat) throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        // Points measured from visible source circles, independently of the
        // generated hit targets. The compound Bond Street outline previously
        // had no separately selectable Central or Jubilee circle.
        let cases: [(CGPoint, String, TubeLineID?, String?)] = [
            (CGPoint(x: 1329.797, y: 1042.117), "940GZZLUBKF", .circle, nil),
            (CGPoint(x: 1356.096, y: 1068.737), "910GBLFR", .thameslink, nil),
            (CGPoint(x: 1366.307, y: 1068.737), "910GBLFR", nil, "national-rail:SE"),
            (CGPoint(x: 1678.642, y: 1349.018), "910GNWCRELL", .windrush, nil),
            (CGPoint(x: 697.065, y: 1078.014), "940GZZLUHSD", .district, nil),
            (CGPoint(x: 1564.994, y: 639.787), "910GCNNB", .windrush, nil),
            (CGPoint(x: 1904.604, y: 655.544), "910GSTFD", .mildmay, nil),
            (CGPoint(x: 1274.892, y: 1744.151), "910GWCROYDN", nil, "national-rail:SN"),
            (CGPoint(x: 2217.435, y: 407.210), "910GROMFORD", nil, "national-rail:LE"),
            (CGPoint(x: 745.243, y: 977.604), "910GSHPDSB", .mildmay, nil),
            (CGPoint(x: 1049.96, y: 886.63), "940GZZLUBND", .central, nil),
            (CGPoint(x: 1010.79, y: 925.78), "940GZZLUBND", .jubilee, nil),
            (CGPoint(x: 1069.28, y: 867.30), "910GBONDST", .elizabeth, nil),
            (CGPoint(x: 1772.09, y: 800.62), "940GZZLUMED", .district, nil),
            (CGPoint(x: 2161.52, y: 719.63), "940GZZLUBKG", .district, nil),
        ]
        for (point, stationID, lineID, operatorID) in cases {
            let selection = try #require(resolve(point, scale: scale, document: document, graph: graph))
            #expect(selection == BeckMapStationTapSelection(stationID: stationID,
                preferredLineID: lineID, preferredOperatorID: operatorID))
        }
    }

    @Test func railPreferenceWaitsForDataAndRespectsThePassengersChoice() {
        var selection = StationDepartureOperatorSelection(preferredID: "national-rail:SW")
        #expect(selection.resolved(availableIDs: [], hasTfLLines: true) == nil)
        #expect(selection.resolved(availableIDs: ["national-rail:SE"], hasTfLLines: true) == nil)
        let operators = ["national-rail:SE", "national-rail:SW"]
        #expect(selection.resolved(availableIDs: operators, hasTfLLines: true) == "national-rail:SW")
        selection.select("national-rail:SE")
        #expect(selection.resolved(availableIDs: operators, hasTfLLines: true) == "national-rail:SE")
        selection.select(nil)
        #expect(selection.resolved(availableIDs: operators, hasTfLLines: true) == nil)
        #expect(selection.resolved(availableIDs: operators, hasTfLLines: false) == "national-rail:SE")
    }

    @Test(arguments: [CGFloat(0.25), 0.5, 1, 3])
    func shadwellAndLimehouseRoundelsOpenTheirOwnDepartureBoards(scale: CGFloat) throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        let defaultsName = "DLRRoundelTapTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let state = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        state.selectedTab = .nearMe
        state.graph = graph
        let cases: [(CGPoint, String, String, TubeLineID)] = [
            (CGPoint(x: 1670.184, y: 988.235), "940GZZDLSHA", "Shadwell DLR Station", .dlr),
            (CGPoint(x: 1732.836, y: 988.074), "940GZZDLLIM", "Limehouse DLR Station", .dlr),
            (CGPoint(x: 1758.476, y: 988.228), "940GZZDLWFE", "Westferry DLR Station", .dlr),
            (CGPoint(x: 1650.312, y: 968.363), "910GSHADWEL", "Shadwell", .windrush),
            (CGPoint(x: 1839.157, y: 988.208), "940GZZDLPOP", "Poplar DLR Station", .dlr),
            (CGPoint(x: 1817.276, y: 1024.169), "940GZZDLWIQ", "West India Quay DLR Station", .dlr),
            (CGPoint(x: 1817.276, y: 1064.357), "940GZZDLCAN", "Canary Wharf DLR Station", .dlr)
        ]
        for (point, stationID, name, lineID) in cases {
            for delta in [CGPoint.zero, CGPoint(x: -2, y: 0), CGPoint(x: 2, y: 0),
                          CGPoint(x: 0, y: -2), CGPoint(x: 0, y: 2)] {
                let selection = try #require(resolve(CGPoint(x: point.x + delta.x, y: point.y + delta.y),
                    scale: scale, document: document, graph: graph))
                #expect(selection.stationID == stationID)
                #expect(selection.preferredLineID == lineID)
                let station = try #require(graph.stationsByID[selection.stationID])
                state.select(station: station, preferredDepartureLineID: selection.preferredLineID)
                #expect(state.selectedStation?.id == stationID)
                #expect(state.selectedStation?.name == name)
                #expect(state.selectedStationDepartureLineID == lineID)
            }
        }
    }

    @Test(arguments: [CGFloat(0.25), 0.5, 1, 3])
    func expandedTargetsKeepNearbyTicksSelectable(scale: CGFloat) throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        let cases: [(CGPoint,String)] = [
            (CGPoint(x: 1477.786, y: 544.840), "940GZZLUASL"),
            (CGPoint(x: 1307.735, y: 1056.760), "940GZZLUTMP"),
            (CGPoint(x: 1735.109, y: 805.891), "940GZZLUSGN"),
            (CGPoint(x: 2173.825, y: 706.738), "940GZZLUUPY"),
            (CGPoint(x: 1965.365, y: 1566.343), "nr:SUP")
        ]
        for (point,stationID) in cases {
            #expect(resolve(point, scale: scale, document: document, graph: graph)?.stationID == stationID)
        }
        // At overview scales this misses the printed circle but still benefits
        // from the larger touch area; a nearby marker must not steal it.
        let rail = resolve(CGPoint(x: 1366.307 + min(9, 20/scale), y: 1068.737),
                           scale: scale, document: document, graph: graph)
        #expect(rail?.stationID == "910GBLFR")
        #expect(rail?.preferredOperatorID == "national-rail:SE")
    }

    @Test func anotherRoundelAtTheSameStationReplacesTheBoardPreference() throws {
        let name = "MapRoundelTapTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let state = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        state.selectedTab = .nearMe
        let graph = try TubeGraph.bundled()
        state.graph = graph
        let station = try #require(graph.stationsByID["910GBLFR"])
        state.select(station: station, preferredDepartureOperatorID: "national-rail:SE")
        #expect(state.selectedStationDepartureOperatorID == "national-rail:SE")
        let generation = state.stationSelectionGeneration
        state.select(station: station, preferredDepartureLineID: .thameslink)
        #expect(state.selectedStationDepartureLineID == .thameslink)
        #expect(state.selectedStationDepartureOperatorID == nil)
        #expect(state.stationSelectionGeneration > generation)
        state.select(station: station, preferredDepartureOperatorID: "national-rail:SE")
        state.selectDepartureLine(.circle)
        #expect(state.selectedStationDepartureOperatorID == nil)
        state.clearStationSelection()
        #expect(state.selectedStationDepartureOperatorID == nil)
    }

    private func resolve(_ point: CGPoint, scale: CGFloat, document: BeckMapDocument,
                         graph: TubeGraph, segments: [BeckMapCanvas.RenderedSegment] = []) -> BeckMapStationTapSelection? {
        let offset = CGSize(width: -381.25, height: 212.5)
        return BeckMapStationTapResolver.resolve(
            screenPoint: CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height),
            cameraScale: scale, cameraOffset: offset, document: document,
            renderedSegments: segments, graph: graph
        )
    }
}

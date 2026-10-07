import Foundation
import MapKit
import Testing
@testable import TubeTrackUK

@MainActor
struct StationMarkerAuditTests {
    @Test(arguments: BeckMapRegion.allCases.filter { $0 != .londonRailAndTube })
    func allNativeMapRegionsRetainStationIdentity(region: BeckMapRegion) throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: region, graph: graph)
        let cache = BeckMapCanvas.RenderCache(document: document)
        for marker in document.stationMarkers {
            let hub = BeckMapStationSelection.stationIDs(for: marker.stationID, in: graph)
            for primitive in marker.primitives {
                let point: CGPoint
                switch primitive {
                case let .circle(circle): point = CGPoint(x: circle.centre.x, y: circle.centre.y)
                case let .tick(tick): point = CGPoint(x: tick.end.x, y: tick.end.y)
                default: continue
                }
                for scale in [CGFloat(0.25), 0.5, 1, 3] {
                    let selection = BeckMapStationTapResolver.resolve(screenPoint: CGPoint(x: point.x * scale, y: point.y * scale),
                        cameraScale: scale, cameraOffset: .zero, document: document,
                        renderedSegments: cache.renderedSegments, graph: graph, exactOnly: true)
                    #expect(selection.map { hub.contains($0.stationID) } == true,
                            "Wrong board in \(region): \(marker.name) at \(point)")
                }
            }
        }
    }

    @Test(arguments: [CGFloat(0.25), 0.5, 1, 3])
    func originalTicksOpenTheirOwnStationAndLine(scale: CGFloat) throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let cache = BeckMapCanvas.RenderCache(document: document)
        for marker in document.stationMarkers {
            let station = try #require(graph.stationsByID[marker.stationID])
            let hub = Set(graph.stations(inSamePlaceAs: station).map(\.id))
            for primitive in marker.primitives {
                guard case let .tick(tick) = primitive else { continue }
                for progress in [0.25, 0.5, 0.75, 1.0] {
                    let point = CGPoint(x: tick.start.x + (tick.end.x - tick.start.x) * progress,
                                        y: tick.start.y + (tick.end.y - tick.start.y) * progress)
                    let selection = BeckMapStationTapResolver.resolve(screenPoint: CGPoint(x: point.x * scale, y: point.y * scale),
                        cameraScale: scale, cameraOffset: .zero, document: document,
                        renderedSegments: cache.renderedSegments, graph: graph)
                    #expect(selection.map { hub.contains($0.stationID) } == true,
                            "Wrong station at \(station.name) \(tick.lineID): \(point), selected \(String(describing: selection))")
                    // Some printed ticks overlap at shared line termini. Accept
                    // only a service whose actual glyph covers this point.
                    let visibleLines = Set(document.stationMarkers.filter { hub.contains($0.stationID) }.flatMap { item in
                        item.primitives.compactMap { primitive -> TubeLineID? in
                            guard case let .tick(other) = primitive,
                                  StationMarkerGeometry.distance(from: point, to: CGPoint(x: other.start.x, y: other.start.y), end: CGPoint(x: other.end.x, y: other.end.y)) <= other.width / 2 + 0.001
                            else { return nil }
                            return other.lineID
                        }
                    })
                    #expect(selection?.preferredLineID.map { visibleLines.contains($0) } == true,
                            "Wrong line at \(station.name) \(tick.lineID): \(point)")
                }
            }
        }
    }
    @Test(arguments: [CGFloat(0.25), 0.5, 1, 3])
    func independentlyReviewedSymbolsOpenTheirOwnDepartureBoard(scale: CGFloat) throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        let offset = CGSize(width: -398.5, height: 184.25)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Tools/NationalRailMapBuilder/reviewed-station-targets.csv")
        let rows = try String(contentsOf: fixture, encoding: .utf8)
            .components(separatedBy: .newlines).filter { !$0.isEmpty }.dropFirst()
        #expect(rows.count == 944)
        let name = "StationMarkerAudit.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let state = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        state.selectedTab = .nearMe // Exercise selection without starting network polling.
        state.graph = graph
        for row in rows {
            let fields = row.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let point = CGPoint(x: try #require(Double(fields[1])), y: try #require(Double(fields[2])))
            let expectedID = fields[3]
            let line = TubeLineID(rawValue: fields[4])
            let operatorID = fields[5].isEmpty ? nil : fields[5]
            let selection = try #require(BeckMapStationTapResolver.resolve(
                screenPoint: CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height),
                cameraScale: scale, cameraOffset: offset, document: document, renderedSegments: [], graph: graph,
                exactOnly: true), "Missing printed \(fields[0]): \(fields[6]) at \(point)")
            #expect(selection == BeckMapStationTapSelection(stationID: expectedID, preferredLineID: line,
                preferredOperatorID: operatorID), "Incorrect board for printed \(fields[6]) at \(point)")
            let station = try #require(graph.stationsByID[selection.stationID])
            #expect(station.name == fields[6])
            state.select(station: station, preferredDepartureLineID: selection.preferredLineID,
                         preferredDepartureOperatorID: selection.preferredOperatorID)
            #expect(state.selectedStation?.id == expectedID)
            if let line { #expect(state.selectedStationDepartureLineID == line) }
            #expect(state.selectedStationDepartureOperatorID == operatorID)
            if operatorID != nil { #expect(!NationalRailStations.codes(for: [expectedID]).isEmpty) }
            let hub = BeckMapStationSelection.stationIDs(for: expectedID, in: graph)
            let highlight = BeckMapStationSelection(document: document, stationIDs: hub)
            #expect(highlight.roundels.contains { hypot($0.centre.x-point.x, $0.centre.y-point.y) < 0.02 })
        }
    }

    @Test func everyLogicalStationHasAVisibleTargetAtItsOwnHub() throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        let ids = Set((document.referenceArtwork?.stationRoundels ?? []).map(\.stationID)
            + (document.referenceArtwork?.stationTicks ?? []).map(\.stationID))
        for station in graph.stations {
            #expect(!BeckMapStationSelection.stationIDs(for: station.id, in: graph).isDisjoint(with: ids),
                    "No physical symbol for \(station.name)")
        }
    }

    @Test(arguments: [CGFloat(0.25), 0.5, 1, 3])
    func pierAndCableSymbolsRetainTheirIdentityAtEveryZoom(scale: CGFloat) throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let network = try #require(RiverBundle.load("RiverNetwork", as: RiverNetwork.self))
        let cable = try #require(RiverBundle.load("CableCarNetwork", as: CableCarNetwork.self))
        for region in [BeckMapRegion.fullUnderground, .londonRailAndTube] {
            let document = try BeckMapRepository().load(region: region, graph: graph)
            let anchors = document.referenceArtwork?.riverAnchors ?? (RiverBundle.load("RiverSchematic", as: [RiverSchematicAnchor].self) ?? [])
            var targets: [MapSymbolHitTesting.Target] = network.piers.compactMap { pier in
                guard let anchor = anchors.first(where: { $0.id == pier.id }) else { return nil }
                return .init(id: "pier:\(pier.id)", point: CGPoint(x: anchor.markerPoint.x * scale,
                    y: anchor.markerPoint.y * scale), radius: BeckRiverLayer.markerRadius(selected: false, scale: scale, document: document))
            }
            targets += cable.terminals.compactMap { terminal in
                guard let p = CableCarSchematic.anchors(in: document)[terminal.id] else { return nil }
                return .init(id: "cable:\(terminal.id)", point: CGPoint(x: p.x * scale, y: p.y * scale), radius: 8.5 * scale)
            }
            #expect(targets.count == 26)
            for target in targets {
                #expect(MapSymbolHitTesting.nearestID(at: target.point, targets: targets) == target.id)
                #expect(BeckMapStationTapResolver.resolve(screenPoint: target.point, cameraScale: scale,
                    cameraOffset: .zero, document: document, renderedSegments: [], graph: graph, exactOnly: true) == nil,
                    "Station geometry intercepts \(target.id)")
            }
        }
    }

    @Test func geographicMarkersSelectTheStationTheyDisplayAcrossTransportTypes() throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let data = RealWorldMapRenderData(graph: graph)
        for selectedID in [nil] + graph.stations.map { Optional($0.id) } {
            let displayed = data.displayStations(selectedStationID: selectedID)
            for station in displayed {
                let id = RealWorldMapSelectionPolicy.stationIDToSelect(mapSelection: station.id,
                    selectedStationID: nil, presentationMode: .realWorld)
                let selected = try #require(id.flatMap { graph.stationsByID[$0] })
                #expect(selected.id == station.id)
                #expect(selected.name == station.name)
                #expect(selected.latitude == station.latitude && selected.longitude == station.longitude)
            }
        }
        // A glyph tap is resolved before the larger boat, cable-route and line
        // hit areas. Nearby transport symbols keep their own annotation tags.
        let symbols: [MapSymbolHitTesting.Target] = [
            .init(id: "940GZZDLRVC", point: CGPoint(x: 10, y: 0), radius: 6.5),
            .init(id: "cable:940GZZALRDK", point: .zero, radius: 5.5),
            .init(id: "pier:930GWOA", point: CGPoint(x: -10, y: 0), radius: 5.5)
        ]
        for symbol in symbols {
            #expect(MapSymbolHitTesting.nearestID(at: symbol.point, targets: symbols) == symbol.id)
        }
    }

}

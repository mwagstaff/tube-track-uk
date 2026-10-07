import Foundation
import Testing
@testable import TubeTrackUK

@MainActor
struct NationalRailMapTests {
    @Test func layerStartsHiddenAndRemembersTheUsersChoice() throws {
        let name = "NationalRailMapTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let state = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        #expect(!state.showsNationalRail)
        state.showsNationalRail = true
        #expect(TubeAppState(defaults: defaults, monitorsConnectivity: false).showsNationalRail)
        state.showsNationalRail = false
        #expect(!TubeAppState(defaults: defaults, monitorsConnectivity: false).showsNationalRail)
    }

    @Test func searchRevealsRailAndHidingClearsExclusiveSelection() throws {
        let name = "NationalRailMapTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let state = TubeAppState(defaults: defaults, monitorsConnectivity: false)
        state.selectedTab = .nearMe // Avoid polling in this state-only test.
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        state.graph = graph
        let station = try #require(StationSearch.suggestions(in: graph, matching: "Bromley North", selectedStationID: nil).first)
        #expect(NationalRailMap.isExclusiveStation(station.id))
        state.select(station: station)
        #expect(state.showsNationalRail)
        #expect(state.selectedStationID == station.id)
        state.showsNationalRail = false
        #expect(state.selectedStationID == nil)
        let thameslink = try #require(graph.stations.first { $0.lineIDs == [.thameslink] })
        state.select(station: thameslink)
        #expect(!state.showsNationalRail)
        #expect(state.selectedStationID == thameslink.id)
    }

    @Test func combinedArtworkAndRouteEndpointsHaveResolvableDepartureStations() throws {
        let base = try TubeGraph.bundled()
        let graph = base.includingNationalRailStations()
        let map = NationalRailMap.bundled
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        let original = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        #expect(original.stationMarkers.count == base.stations.count)
        #expect(graph.lines == base.lines)
        #expect(map.stations.count > 150)
        #expect(map.routes.count > 280)
        #expect(document.referenceArtwork?.shapes.isEmpty == false)
        #expect(Set(document.segments.map(\.id)) == Set(base.segments.map(\.id)))
        let artwork = try #require(document.referenceArtwork)
        let river = try #require(artwork.shapes.first { $0.role == .waterway })
        #expect(river.fill != nil && river.commands.count > 100)
        #expect(!artwork.texts.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "fare zone" })
        #expect(artwork.stationLabels?.count == document.stationMarkers.count)
        let bromleyLabel = try #require(artwork.stationLabels?.first { $0.stationID == "nr:BMN" })
        #expect(artwork.stationID(at: CGPoint(x: bromleyLabel.centre.x, y: bromleyLabel.centre.y)) == "nr:BMN")
        #expect(artwork.riverAnchors?.count == 24)
        #expect(artwork.cableCarAnchors?.count == 2)
        for anchor in artwork.riverAnchors ?? [] {
            #expect(anchor.x >= 0 && anchor.x < document.artworkSize.width)
            #expect(anchor.y >= 0 && anchor.y < document.artworkSize.height)
        }
        let markerIDs = Set(document.stationMarkers.map(\.stationID))
        for station in map.stations {
            #expect(markerIDs.contains(station.id), "No map target for \(station.name)")
            #expect(!NationalRailStations.codes(for: [station.id]).isEmpty)
            let marker = try #require(document.stationMarkers.first { $0.stationID == station.id })
            let hit = BeckMapStationMarkerHitTester.nearestMarker(
                to: CGPoint(x: marker.anchor.x, y: marker.anchor.y),
                among: document.stationMarkers, minimumHitRadius: 0
            )
            #expect(hit?.stationID == station.id, "Ambiguous station target for \(station.name)")
        }
        for route in map.routes {
            #expect(graph.stationsByID[route.fromStationID] != nil)
            #expect(graph.stationsByID[route.toStationID] != nil)
            #expect(route.geographicPoints.count >= 2)
            #expect(route.geographicPoints.allSatisfy { $0.latitude.isFinite && $0.longitude.isFinite })
        }
        let leaBridge = try #require(map.stations.first { $0.name == "Lea Bridge" })
        #expect(abs(leaBridge.longitude - -0.036673) < 0.00001)
    }

    @Test(arguments: [CGFloat(0.5), 1, 3])
    func greenwichPierLinksToCuttySarksVisibleRoundel(cameraScale: CGFloat) throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        let pier = try #require(document.referenceArtwork?.riverAnchors?.first { $0.id == "930GGNW" })
        #expect(pier.walkingLinkStationIDs == ["940GZZDLCUT"])
        #expect(hypot(pier.markerPoint.x - 1798.152, pier.markerPoint.y - 1234.880) < 0.01)

        // Measured from the source's visible circle, independently of the
        // semantic target that previously landed on Maze Hill's tick.
        let cuttySark = CGPoint(x: 1817.296, y: 1253.212)
        let roundel = try #require(BeckMapWalkingLink.roundel(of: "940GZZDLCUT", nearest: pier.markerPoint, in: document))
        #expect(hypot(roundel.centre.x - cuttySark.x, roundel.centre.y - cuttySark.y) < 0.01)
        let linkSpan = hypot(cuttySark.x - pier.markerPoint.x, cuttySark.y - pier.markerPoint.y) * cameraScale
        #expect(pier.walkingLinksInArtwork == true)
        #expect(linkSpan > BeckRiverLayer.markerRadius(selected: false, scale: cameraScale, document: document)
                + roundel.outerRadius * cameraScale + BeckMapWalkingLink.width(in: document) * cameraScale)
        let selection = BeckMapStationTapResolver.resolve(
            screenPoint: CGPoint(x: cuttySark.x * cameraScale, y: cuttySark.y * cameraScale),
            cameraScale: cameraScale, cameraOffset: .zero, document: document,
            renderedSegments: [], graph: graph
        )
        #expect(selection?.stationID == "940GZZDLCUT")
        #expect(selection?.preferredLineID == .dlr)
    }

    @Test func allReferencePiersUseNativeSymbolsAtTheirWalkingLinks() throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        let artwork = try #require(document.referenceArtwork)
        let anchors = try #require(artwork.riverAnchors)
        #expect(anchors.filter { $0.walkingLinksInArtwork == true }.count == 12)
        let expected: [(String, CGPoint)] = [
            ("930GBRVS", CGPoint(x: 2274.008, y: 796.708)),
            ("930GWAS", CGPoint(x: 2062.940, y: 1215.352)),
            ("930GMIL", CGPoint(x: 1922.428, y: 1068.836)),
            ("930GCHP", CGPoint(x: 827.272, y: 1314.852)),
            ("930GWMP", CGPoint(x: 1158.444, y: 1110.248))
        ]
        for (id, point) in expected {
            let anchor = try #require(anchors.first { $0.id == id })
            #expect(hypot(anchor.markerPoint.x - point.x, anchor.markerPoint.y - point.y) < 0.01)
            #expect(anchor.walkingLinksInArtwork == true)
        }
        #expect(Set(artwork.additionalRiverPiers?.map(\.name) ?? []) == ["Kingston Turks", "Hampton Court Pier"])
        #expect(artwork.riverWalkingLinks?.count == 14)
        // No repeated source ferry glyph survives, including those beside labels.
        #expect(!artwork.shapes.contains { shape in
            guard let fill = shape.fill, fill.count == 3 else { return false }
            return abs(fill[0] - 0.16548) < 0.0001 && abs(fill[1] - 0.20073) < 0.0001
                && abs(fill[2] - 0.55415) < 0.0001 && shape.commands.count == 61
        })
    }

    @Test(arguments: [CGFloat(0.5), 1, 3])
    func londonBridgePierLinksDiagonallyToItsVisibleRoundel(cameraScale: CGFloat) throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        let pier = try #require(document.referenceArtwork?.riverAnchors?.first { $0.id == "930GLBR" })
        let station = try #require(BeckMapWalkingLink.roundel(of: "940GZZLULNB", nearest: pier.markerPoint, in: document))
        // These are the actual Northern-line circle coordinates in the source.
        #expect(hypot(station.centre.x - 1399.616, station.centre.y - 1133.499) < 0.01)
        let bend = try #require(pier.walkingLinkVia?.first)
        let dx = pier.markerPoint.x - bend.x
        let dy = bend.y - pier.markerPoint.y
        #expect(dx > 0 && dy > 0)
        #expect(abs(dx - dy) < 0.001)
        #expect(abs(bend.y - station.centre.y) < 0.001)
        #expect(bend.x > station.centre.x + station.outerRadius * 2)
        #expect(pier.offsetY > 0)
        #expect(pier.walkingLinkStationIDs == ["940GZZLULNB"])
        #expect(hypot(dx, dy) * cameraScale > station.outerRadius * cameraScale
                + BeckRiverLayer.markerRadius(selected: false, scale: cameraScale, document: document))
        let path = try #require(BeckMapWalkingLink.path(
            from: CGPoint(x: pier.markerPoint.x * cameraScale, y: pier.markerPoint.y * cameraScale),
            startRadius: BeckRiverLayer.markerRadius(selected: false, scale: cameraScale, document: document),
            to: CGPoint(x: station.centre.x * cameraScale, y: station.centre.y * cameraScale),
            endRadius: station.outerRadius * cameraScale,
            via: [CGPoint(x: bend.x * cameraScale, y: bend.y * cameraScale)]
        ))
        let end = try #require(path.currentPoint)
        #expect(abs(end.x - (station.centre.x + station.outerRadius) * cameraScale) < 0.01)
        #expect(abs(end.y - station.centre.y * cameraScale) < 0.01)
        let label = try #require(document.referenceArtwork?.stationLabels?.first { $0.stationID == "940GZZLULNB" })
        let selection = BeckMapStationTapResolver.resolve(
            screenPoint: CGPoint(x: label.centre.x * cameraScale, y: label.centre.y * cameraScale),
            cameraScale: cameraScale, cameraOffset: .zero, document: document, renderedSegments: [], graph: graph
        )
        #expect(selection?.stationID == "940GZZLULNB")
    }

    @Test func straightWalkingLinksStillStopAtBothSymbolEdges() throws {
        let path = try #require(BeckMapWalkingLink.path(from: .zero, startRadius: 3,
                                                       to: CGPoint(x: 0, y: 30), endRadius: 7))
        #expect(path.boundingRect.minY == 3)
        #expect(path.currentPoint == CGPoint(x: 0, y: 23))
    }

    @Test func combinedCableTerminalsWalkToStationsOnTheirOwnRiverBanks() throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        let anchors = CableCarSchematic.anchors(in: document)
        let expected: [(String, String, CGPoint)] = [
            ("940GZZALGWP", "940GZZLUNGW", CGPoint(x: 1927.647, y: 1103.523)),
            ("940GZZALRDK", "940GZZDLRVC", CGPoint(x: 2065.291, y: 1016.182))
        ]
        let southBank = (343.9 - 79) * 4 + 7
        for (terminalID, stationID, sourcePoint) in expected {
            let terminal = try #require(anchors[terminalID])
            #expect(hypot(terminal.x - sourcePoint.x, terminal.y - sourcePoint.y) < 0.01)
            let station = try #require(BeckMapWalkingLink.roundel(of: stationID, nearest: terminal, in: document))
            #expect(hypot(terminal.x - station.centre.x, terminal.y - station.centre.y) < 30)
            if terminalID == "940GZZALGWP" {
                // Both ends of this walk are south of the horizontal river reach.
                #expect(terminal.y > southBank && station.centre.y > southBank)
            } else {
                #expect(terminal.y < (343.9 - 79) * 4 - 7)
                #expect(station.centre.y < (343.9 - 79) * 4 - 7)
            }
        }
        let points = CableCarSchematic.points(in: document)
        #expect(points.first == anchors["940GZZALGWP"])
        #expect(points.last == anchors["940GZZALRDK"])
    }

    @Test(arguments: [CGFloat(0.2), 0.35, 0.5, 1, 3])
    func pierDiscsScaleWithStationRoundelsInBothMaps(cameraScale: CGFloat) throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        for region in [BeckMapRegion.fullUnderground, .londonRailAndTube] {
            let document = try BeckMapRepository().load(region: region, graph: graph)
            let roundel = try #require(BeckMapWalkingLink.roundel(of: "940GZZDLCUT", nearest: .zero, in: document))
            let radius = BeckRiverLayer.markerRadius(selected: false, scale: cameraScale, document: document)
            #expect(abs(radius - roundel.outerRadius * cameraScale) < 0.05 * cameraScale)
            let selected = BeckRiverLayer.markerRadius(selected: true, scale: cameraScale, document: document)
            #expect(selected <= radius * 1.16)
        }
    }

    @Test(arguments: [CGFloat(0.5), 1, 3])
    func newCrossRoundelAndLabelSelectTheCorrectStation(cameraScale: CGFloat) throws {
        let graph = try TubeGraph.bundled().includingNationalRailStations()
        let document = try BeckMapRepository().load(region: .londonRailAndTube, graph: graph)
        let artwork = try #require(document.referenceArtwork)
        let station = try #require(graph.stationsByID["910GNWCRELL"])
        #expect(station.name == "New Cross")
        #expect(StationSearch.suggestions(in: graph, matching: "New Cross ELL").first?.id == station.id)

        // Coordinates from the visible reference vectors, independent of the
        // semantic hit target, which used to sit on a walking-link dot.
        let roundel = CGPoint(x: 1678.641, y: 1349.016)
        let gateRoundel = CGPoint(x: 1649.860, y: 1377.956)
        let offset = CGSize(width: -320, height: 90)
        for (point, stationID) in [(roundel, station.id), (gateRoundel, "910GNEWXGTE")] {
            let selection = BeckMapStationTapResolver.resolve(
                screenPoint: CGPoint(x: point.x * cameraScale + offset.width,
                                     y: point.y * cameraScale + offset.height),
                cameraScale: cameraScale,
                cameraOffset: offset,
                document: document,
                renderedSegments: [],
                graph: graph
            )
            #expect(selection?.stationID == stationID)
            #expect(selection?.preferredLineID == .windrush)
        }
        #expect(artwork.stationID(at: CGPoint(x: 1709.535, y: 1339.102)) == station.id)
        #expect(artwork.stationID(at: CGPoint(x: 1669.144, y: 1382.096)) == "910GNEWXGTE")

        let standard = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        #expect(standard.stationMarkers.first { $0.stationID == station.id }?.name == "New Cross")
        #expect(standard.labels.first { $0.stationID == station.id }?.text == "New Cross")
    }
}

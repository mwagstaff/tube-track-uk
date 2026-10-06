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
}

import Testing
@testable import TubeTrackUK

struct StationSearchTests {
    @Test func ranksExactAndPrefixStationNamesAheadOfLooseMatches() {
        let stations = [
            station(id: "bank", name: "Bank"),
            station(id: "bankside", name: "Bankside"),
            station(id: "embankment", name: "Embankment"),
        ]

        let results = StationSearch.suggestions(in: stations, matching: "bank")

        #expect(results.map(\.id) == ["bank", "bankside", "embankment"])
    }

    @Test func matchesAliasesCaseInsensitively() {
        let stations = [
            station(
                id: "kings-cross",
                name: "King’s Cross St Pancras",
                aliases: ["Kings Cross", "St Pancras"]
            ),
            station(id: "crossharbour", name: "Crossharbour"),
        ]

        let results = StationSearch.suggestions(in: stations, matching: "KINGS CROSS")

        #expect(results.map(\.id) == ["kings-cross"])
    }

    @Test func matchesMultipleWordsAcrossAStationName() {
        let stations = [
            station(id: "tottenham-court-road", name: "Tottenham Court Road"),
            station(id: "tottenham-hale", name: "Tottenham Hale"),
        ]

        let results = StationSearch.suggestions(in: stations, matching: "tot court")

        #expect(results.map(\.id) == ["tottenham-court-road"])
    }

    @Test func findsLondonTramStopsWithoutRequiringTheModeSuffix() {
        let stations = [
            station(id: "east-croydon", name: "East Croydon", lineIDs: [.tram]),
            station(id: "east-finchley", name: "East Finchley"),
        ]

        let results = StationSearch.suggestions(in: stations, matching: "east croy")

        #expect(results.map(\.id) == ["east-croydon"])
        #expect(results.first?.lineIDs == [.tram])
    }

    @Test func bundledHubSearchDeduplicatesTramInterchangesAndPreservesSelection() throws {
        let graph = try TubeGraph.bundled()

        let selectedDistrictWimbledon = StationSearch.suggestions(
            in: graph,
            matching: "Wimbledon",
            selectedStationID: "940GZZLUWIM",
            limit: 40
        )
        #expect(selectedDistrictWimbledon.filter { $0.name == "Wimbledon" }.map(\.id) == ["940GZZLUWIM"])

        let selectedTramWimbledon = StationSearch.suggestions(
            in: graph,
            matching: "Wimbledon",
            selectedStationID: "940GZZCRWMB",
            limit: 40
        )
        #expect(selectedTramWimbledon.filter { $0.name == "Wimbledon" }.map(\.id) == ["940GZZCRWMB"])

        let westCroydon = StationSearch.suggestions(
            in: graph,
            matching: "West Croydon",
            limit: 40
        )
        #expect(westCroydon.count == 1)
        #expect(Set(graph.lineIDs(at: try #require(westCroydon.first))) == [.tram, .windrush])
    }

    @Test func stationDisruptionLookupIncludesEveryStopAtAHub() throws {
        let graph = try TubeGraph.bundled()
        let westCroydonRail = try #require(graph.stationsByID["910GWCROYDN"])
        let wimbledonTram = try #require(graph.stationsByID["940GZZCRWMB"])
        let tramIssue = disruption(
            id: "tram-west-croydon",
            lineID: .tram,
            affectedStationID: "940GZZCRWCR"
        )
        let districtIssue = disruption(
            id: "district-wimbledon",
            lineID: .district,
            affectedStationID: "940GZZLUWIM"
        )

        #expect(StationDisruptionLookup.firstMatching(
            station: westCroydonRail,
            graph: graph,
            disruptions: [tramIssue]
        )?.id == tramIssue.id)
        #expect(StationDisruptionLookup.firstMatching(
            station: wimbledonTram,
            graph: graph,
            disruptions: [districtIssue]
        )?.id == districtIssue.id)
    }

    private func station(
        id: String,
        name: String,
        aliases: [String] = [],
        lineIDs: [TubeLineID] = [.central]
    ) -> TubeStation {
        TubeStation(
            id: id,
            name: name,
            latitude: 0,
            longitude: 0,
            schematicX: 0,
            schematicY: 0,
            lineIDs: lineIDs,
            interchange: false,
            searchAliases: aliases,
            hubID: nil
        )
    }

    private func disruption(
        id: String,
        lineID: TubeLineID,
        affectedStationID: String
    ) -> ResolvedDisruption {
        ResolvedDisruption(
            id: id,
            lineID: lineID,
            title: "Part Closure",
            reason: "Testing hub resolution",
            severity: 5,
            affectedStationIDs: [affectedStationID],
            affectedSegmentIDs: [],
            confidence: .exact
        )
    }
}

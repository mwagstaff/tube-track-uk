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

    private func station(
        id: String,
        name: String,
        aliases: [String] = []
    ) -> TubeStation {
        TubeStation(
            id: id,
            name: name,
            latitude: 0,
            longitude: 0,
            schematicX: 0,
            schematicY: 0,
            lineIDs: [.central],
            interchange: false,
            searchAliases: aliases,
            hubID: nil
        )
    }
}

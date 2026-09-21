import Foundation
import Testing
@testable import TubeTrackCore

struct StationIndexTests {
    private let index = StationIndex.bundled

    @Test func bundledIndexMatchesTheAppGraph() throws {
        // Tools/StationIndexBuilder derives StationIndex.json from
        // TubeGraph.json; this guards against the two drifting apart.
        let graphURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TubeTrackCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // TubeTrackCore
            .deletingLastPathComponent() // ios
            .appending(path: "TubeTrackUK/Resources/TubeGraph.json")
        let graph = try JSONDecoder().decode(GraphFile.self, from: Data(contentsOf: graphURL))

        #expect(index.schemaVersion == graph.schemaVersion)
        #expect(index.entries.count == graph.stations.count)
        #expect(Set(index.entries.map(\.id)) == Set(graph.stations.map(\.id)))
        for station in graph.stations {
            let entry = try #require(index.entry(id: station.id))
            #expect(entry.name == station.name)
            #expect(entry.hubID == (station.hubID ?? station.id))
            #expect(entry.lineIDs.map(\.rawValue) == station.lineIDs)
        }
    }

    @Test func hubsCollapseColocatedStopPointsUnderThePlainName() throws {
        let bank = try #require(index.hub(containing: "940GZZDLBNK"))
        #expect(bank.id == "HUBBAN")
        #expect(bank.name == "Bank")
        #expect(bank.stopIDs == ["940GZZDLBNK", "940GZZLUBNK"])
        #expect(bank.lineIDs.contains(.dlr))
        #expect(bank.lineIDs.contains(.central))
        #expect(index.hub(containing: "HUBBAN")?.id == "HUBBAN")
    }

    @Test func searchRanksExactAndPrefixMatchesFirstAndDeduplicatesHubs() {
        let results = index.search("king", limit: 5)
        #expect(results.count == 5)
        #expect(results.allSatisfy { $0.name.localizedCaseInsensitiveContains("king") })
        #expect(Set(results.map(\.id)).count == results.count)
        #expect(index.search("king's cross").first?.name == "King's Cross St. Pancras")

        let bank = index.search("Bank")
        #expect(bank.first?.name == "Bank")
        #expect(bank.filter { $0.id == "HUBBAN" }.count == 1)
    }

    @Test func displayNameDropsModeSuffixes() {
        let entry = StationIndexEntry(id: "x", hubID: "x", name: "Abbey Road DLR Station", lineIDs: [.dlr])
        #expect(entry.displayName == "Abbey Road")
        let plain = StationIndexEntry(id: "y", hubID: "y", name: "Battersea Power Station", lineIDs: [.northern])
        #expect(plain.displayName == "Battersea Power Station")
    }

    private struct GraphFile: Decodable {
        struct Station: Decodable {
            let id: String
            let name: String
            let hubID: String?
            let lineIDs: [String]
        }
        let schemaVersion: Int
        let stations: [Station]
    }
}

extension StationIndexTests {
    /// The departures widget suggests these hubs before the passenger searches.
    @Test func widgetFallbackSuggestionsExist() {
        for id in ["HUBKGX", "940GZZLUOXC", "HUBBAN", "HUBWAT", "HUBVIC", "HUBLST", "HUBPAD", "HUBSRA"] {
            #expect(index.hub(containing: id) != nil, "\(id)")
        }
    }
}

import Foundation
import Testing
@testable import TubeTrackUK

struct JourneyMapTests {
    @Test func providerAliasesAndMissingIDsResolveTheWholeDLRElizabethJourney() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let journey = try JSONDecoder.tfl.decode(PlannedJourney.self, from: Data(Self.fixture.utf8))
        let highlight = JourneyMapResolver(graph: graph, document: document).resolve(journey)
        #expect(highlight.unmappedLegCount == 0)
        #expect(!highlight.segmentIDs.isEmpty)
        let segments = document.segments.filter { highlight.segmentIDs.contains($0.id) }
        #expect(Set(segments.map(\.lineID)) == [.dlr, .elizabeth])
        #expect(segments.contains { $0.fromStationID == "910GPADTLL" || $0.toStationID == "910GPADTLL" })
        #expect(!segments.contains { $0.fromStationID == "910GPADTON" || $0.toStationID == "910GPADTON" })
        #expect(highlight.stationIDs.contains("940GZZDLABR"))
        #expect(highlight.stationIDs.contains("910GACTONML"))
        #expect(highlight.stationIDs.contains("910GSTFD"))
        #expect(journey.distinctLines.map(\.tubeLineID) == [.dlr, .elizabeth])
    }

    @Test func missingStationsDoNotProduceGuessedRoutes() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        let missing = Self.fixture.replacingOccurrences(of: "940GZZDLABR", with: "UNKNOWN")
            .replacingOccurrences(of: "Abbey Road DLR Station", with: "Unknown station")
        let journey = try JSONDecoder.tfl.decode(PlannedJourney.self, from: Data(missing.utf8))
        let highlight = JourneyMapResolver(graph: graph, document: document).resolve(journey)
        #expect(highlight.unmappedLegCount == 1)
        #expect(!document.segments.contains { $0.lineID == .dlr && highlight.segmentIDs.contains($0.id) })
    }

    @Test func northernBranchesNeedAnIntermediateStopToChooseTheCorrectPath() throws {
        let graph = try TubeGraph.bundled()
        let document = try BeckMapRepository().load(region: .fullUnderground, graph: graph)
        var raw = try #require(JSONSerialization.jsonObject(with: Data(Self.fixture.utf8)) as? [String: Any])
        var leg = try #require((raw["legs"] as? [[String: Any]])?.first)
        leg["mode"] = "tube"
        leg["from"] = ["id": "940GZZLUEUS", "name": "Euston"]
        leg["to"] = ["id": "940GZZLUKNG", "name": "Kennington"]
        leg["lines"] = [["id": "northern", "name": "Northern", "direction": "Kennington"]]
        leg["stops"] = []
        raw["legs"] = [leg]
        let ambiguous = try JSONDecoder.tfl.decode(PlannedJourney.self, from: JSONSerialization.data(withJSONObject: raw))
        let resolver = JourneyMapResolver(graph: graph, document: document)
        #expect(resolver.resolve(ambiguous).unmappedLegCount == 1)
        #expect(resolver.resolve(ambiguous).segmentIDs.isEmpty)

        leg["stops"] = [["id": "940GZZLUBNK", "name": "Bank"]]
        raw["legs"] = [leg]
        let bank = try JSONDecoder.tfl.decode(PlannedJourney.self, from: JSONSerialization.data(withJSONObject: raw))
        let resolved = resolver.resolve(bank)
        #expect(resolved.unmappedLegCount == 0)
        let segments = document.segments.filter { resolved.segmentIDs.contains($0.id) }
        #expect(segments.contains { $0.fromStationID == "940GZZLUBNK" || $0.toStationID == "940GZZLUBNK" })
        #expect(!segments.contains { $0.fromStationID == "940GZZLUCHX" || $0.toStationID == "940GZZLUCHX" })
    }

    @Test func lineColoursUseKnownIDsAndProviderAliases() {
        #expect(JourneyLine(id: "elizabeth-line", name: "Elizabeth line", direction: "").tubeLineID == .elizabeth)
        #expect(JourneyLine(id: "route-1", name: "Windrush line", direction: "").tubeLineID == .windrush)
        #expect(JourneyLine(id: "unrecognized", name: "Unknown", direction: "").tubeLineID == nil)
    }

    private static let fixture = #"""
    {
      "id": "ad4121c6891f7bc91329",
      "departureTime": "2026-09-16T14:22:00.000Z",
      "arrivalTime": "2026-09-16T15:00:00.000Z",
      "durationMinutes": 38,
      "changes": 2,
      "walkingMinutes": 0,
      "disruptionScore": 0,
      "warnings": [],
      "legs": [
        {
          "id": "0",
          "mode": "dlr",
          "instruction": "DLR to Stratford DLR Station",
          "from": {
            "id": "940GZZDLABR",
            "name": "Abbey Road DLR Station",
            "platform": null
          },
          "to": {
            "id": "940GZZDLSTD",
            "name": "Stratford DLR Station",
            "platform": null
          },
          "lines": [
            {
              "id": "dlr",
              "name": "DLR",
              "direction": "Stratford International DLR Station"
            }
          ],
          "departureTime": "2026-09-16T14:22:00.000Z",
          "arrivalTime": "2026-09-16T14:25:00.000Z",
          "scheduledDepartureTime": "2026-09-16T14:22:00.000Z",
          "scheduledArrivalTime": "2026-09-16T14:25:00.000Z",
          "timing": "estimated",
          "durationMinutes": 3,
          "warnings": [],
          "stops": [
            {
              "id": "940GZZDLSHS",
              "name": "Stratford High Street DLR Station"
            },
            {
              "id": "940GZZDLSTD",
              "name": "Stratford DLR Station"
            }
          ]
        },
        {
          "id": "1",
          "mode": "elizabeth-line",
          "instruction": "Elizabeth line to Whitechapel Station",
          "from": {
            "id": "910GSTFD",
            "name": "Stratford (London) Rail Station",
            "platform": null
          },
          "to": {
            "id": "910GWCHAPXR",
            "name": "Whitechapel",
            "platform": null
          },
          "lines": [
            {
              "id": "elizabeth",
              "name": "Elizabeth line",
              "direction": "Paddington Station"
            }
          ],
          "departureTime": "2026-09-16T14:31:00.000Z",
          "arrivalTime": "2026-09-16T14:36:00.000Z",
          "scheduledDepartureTime": "2026-09-16T14:31:00.000Z",
          "scheduledArrivalTime": "2026-09-16T14:36:00.000Z",
          "timing": "estimated",
          "durationMinutes": 5,
          "warnings": [],
          "stops": [
            {
              "id": "910GWCHAPXR",
              "name": "Whitechapel"
            }
          ]
        },
        {
          "id": "2",
          "mode": "elizabeth-line",
          "instruction": "Elizabeth line to Acton Main Line Station",
          "from": {
            "id": "910GWCHAPXR",
            "name": "Whitechapel",
            "platform": null
          },
          "to": {
            "id": "910GACTONML",
            "name": "Acton Main Line Rail Station",
            "platform": null
          },
          "lines": [
            {
              "id": "elizabeth",
              "name": "Elizabeth line",
              "direction": "Heathrow Terminal 4"
            }
          ],
          "departureTime": "2026-09-16T14:39:00.000Z",
          "arrivalTime": "2026-09-16T15:00:00.000Z",
          "scheduledDepartureTime": "2026-09-16T14:39:00.000Z",
          "scheduledArrivalTime": "2026-09-16T15:00:00.000Z",
          "timing": "estimated",
          "durationMinutes": 21,
          "warnings": [],
          "stops": [
            {
              "id": "",
              "name": "Liverpool Street Station"
            },
            {
              "id": "910GFRNDXR",
              "name": "Farringdon"
            },
            {
              "id": "910GTOTCTRD",
              "name": "Tottenham Court Road"
            },
            {
              "id": "910GBONDST",
              "name": "Bond Street"
            },
            {
              "id": "910GPADTON",
              "name": "London Paddington Rail Station"
            },
            {
              "id": "910GACTONML",
              "name": "Acton Main Line Rail Station"
            }
          ]
        }
      ],
      "labels": [
        "earliestArrival"
      ],
      "waitingMinutes": 6
    }
    """#
}

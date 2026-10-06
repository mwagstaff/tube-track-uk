import Foundation
import Testing
@testable import TubeTrackCore

struct NationalRailDeparturesTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func railStationsCoverEveryMappedRailStopAndMainlineInterchanges() {
        for station in StationIndex.bundled.entries where station.id.hasPrefix("910G") {
            #expect(!NationalRailStations.codes(for: [station.id]).isEmpty, "Missing \(station.name)")
        }
        #expect(NationalRailStations.codes(for: ["940GZZLUVIC"]) == ["VIC"])
        #expect(NationalRailStations.codes(for: ["940GZZLUKSX", "910GSTPXBOX"]) == ["KGX", "STP"])
        #expect(NationalRailStations.codes(for: ["940GZZLUBKF", "910GBLFR"]) == ["BFR"])
        #expect(NationalRailStations.codes(for: ["910GCTMSLNK"]) == ["CTK"])
        #expect(NationalRailStations.codes(for: ["940GZZLUOXC"]).isEmpty)
    }

    @Test func datesCrossMidnightAndUseLondonTimeAcrossClockChanges() {
        #expect(NationalRailDeparture.clockDate("00:17", near: date("2026-10-05T22:50:00Z")) == date("2026-10-05T23:17:00Z"))
        #expect(NationalRailDeparture.clockDate("23:55", near: date("2026-10-05T23:05:00Z")) == date("2026-10-05T22:55:00Z"))
        #expect(NationalRailDeparture.clockDate("01:30", near: date("2026-10-25T00:20:00Z")) == date("2026-10-25T00:30:00Z"))
        #expect(NationalRailDeparture.clockDate("01:30", near: date("2026-10-25T01:20:00Z")) == date("2026-10-25T01:30:00Z"))
        #expect(NationalRailDeparture.clockDate("01:30", near: date("2026-03-29T00:20:00Z")) == nil)
        #expect(NationalRailDeparture.clockDate("Delayed", near: .now) == nil)
    }

    @Test func normalizationPreservesOperatorsDividingTrainsAndCancellationAndHidesSuppressedPlatforms() throws {
        let now = date("2026-10-05T22:50:00Z")
        let row: [String: Any] = ["serviceID": "se-1", "operator": "Southeastern", "operatorCode": "SE",
            "departure_time": ["scheduled": "23:55", "estimated": "Cancelled"],
            "destination": [["crs": "VIC", "locationName": "London Victoria"], ["crs": "ORP", "locationName": "Orpington"]],
            "platform": "2", "platformIsHidden": true, "cancelReason": "Signal failure"]
        let board = try decode([row, row], at: now)
        let predictions = board.predictions(crs: "KTH", now: now)
        #expect(predictions.count == 1)
        let p = try #require(predictions.first)
        #expect(p.isCancelled && p.isNationalRailOperator)
        #expect(p.operatorName == "Southeastern")
        #expect(p.destinationName == "London Victoria & Orpington")
        #expect(p.platformName == "Platform to be confirmed")
        #expect(p.serviceCause == "Signal failure")
        #expect(NationalRailDepartureGroup.groups(from: predictions).first?.name == "Southeastern")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let restored = try JSONDecoder.tfl.decode(TfLArrivalPrediction.self, from: encoder.encode(p))
        #expect(restored.operatorName == p.operatorName)
    }

    @Test func omitsExistingTfLServicesBusesAndAlreadyDepartedTrains() throws {
        let now = date("2026-10-05T22:50:00Z")
        let base: [String: Any] = ["departure_time": ["scheduled": "23:55", "estimated": "On time"],
                                 "destination": ["crs": "VIC", "locationName": "London Victoria"]]
        let variants: [[String: Any]] = [
            ["serviceID": "1", "operator": "Thameslink", "operatorCode": "TL"],
            ["serviceID": "2", "operator": "Elizabeth line", "operatorCode": "XR"],
            ["serviceID": "3", "operator": "London Overground", "operatorCode": "LO"],
            ["serviceID": "4", "operator": "Southern", "serviceType": "bus"],
            ["serviceID": "5", "operator": "Southern", "departure_time": ["scheduled": "23:45", "actual": "23:49"]],
            ["serviceID": "6", "operator": "Southern", "operatorCode": "SN"]
        ]
        let board = try decode(variants.map { base.merging($0) { _, new in new } }, at: now)
        #expect(board.predictions(crs: "KTH", now: now).map(\.operatorName) == ["Southern"])
    }

    @Test func thameslinkBoardsAreIncludedAtNewStationsWithoutATfLBoard() throws {
        let now = date("2026-10-05T22:50:00Z")
        let board = try decode([["serviceID": "tl", "operator": "Thameslink", "operatorCode": "TL",
                                "departure_time": ["scheduled": "23:55", "estimated": "On time"],
                                "destination": ["crs": "BTN", "locationName": "Brighton"]]], at: now)
        #expect(board.predictions(crs: "SAC", now: now).isEmpty)
        #expect(board.predictions(crs: "SAC", now: now, includeThameslink: true).first?.operatorName == "Thameslink")
    }

    @Test func delayedAndUnknownForecastsNeverBecomeDue() throws {
        let now = date("2026-10-05T22:50:00Z")
        for estimate in ["Delayed", "No report"] {
            let board = try decode([["serviceID": estimate, "operator": "Southern",
                "departure_time": ["scheduled": "23:40", "estimated": estimate]]], at: now)
            let p = try #require(board.predictions(crs: "VIC", now: now).first)
            #expect(p.expectedArrival == nil)
            #expect(StationDepartureMetadata.departureTime(for: p, now: now) != "Due")
        }
        let oldBoard = try decode([["serviceID": "old", "operator": "Southern",
            "departure_time": ["scheduled": "23:55", "estimated": "On time"]]], at: now)
        #expect(oldBoard.predictions(crs: "VIC", now: now.addingTimeInterval(24 * 3600)).isEmpty)
    }

    private func decode(_ rows: [[String: Any]], at date: Date) throws -> NationalRailBoard {
        let data = try JSONSerialization.data(withJSONObject: ["departures": rows, "dataStatus": "live",
            "lastSuccessfulUpdate": date.ISO8601Format()])
        return try JSONDecoder.tfl.decode(NationalRailBoard.self, from: data)
    }
}

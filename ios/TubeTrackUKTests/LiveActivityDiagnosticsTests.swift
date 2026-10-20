import Foundation
import Testing
@testable import TubeTrackUK

@Suite(.serialized)
struct LiveActivityDiagnosticsTests {
    @Test func capsExportAndStoredHistory() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "events.json")
        let now = Date()
        let events = (0..<2100).map {
            LiveActivityDiagnostics.Event(date: now, name: "event-\($0)", fields: [:])
        }
        try JSONEncoder().encode(events).write(to: file)
        let logger = LiveActivityDiagnostics(fileURL: file)
        let report = try await logger.export(metadata: [:], now: now)
        let saved = try JSONDecoder().decode([LiveActivityDiagnostics.Event].self, from: Data(contentsOf: file))
        #expect(saved.count == 2000)
        #expect(saved.first?.name == "event-100")
        #expect(saved.last?.name == "event-2099")
        let exported = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
        #expect((exported["events"] as? [Any])?.count == 2000)
    }

    @Test func persistsAcrossInstancesAndExpiresOldEventsWithoutSecrets() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "events.json")
        let now = Date()
        let logger = LiveActivityDiagnostics(fileURL: file)
        logger.record("expired", now: now.addingTimeInterval(-8 * 86400))
        logger.record("registration", fields: ["activityID": "scheduled-example",
            "token": "must-not-appear", "ScheduleCredentials": "must-not-appear",
            "httpStatus": "201"], now: now)
        // Export waits behind all pending writes on the serial queue.
        _ = try await logger.export(metadata: [:], now: now)
        let reopened = LiveActivityDiagnostics(fileURL: file)
        let report = try await reopened.export(metadata: ["build": "test"], now: now)
        let data = try Data(contentsOf: report)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("must-not-appear"))
        #expect(!text.contains("expired"))
        #expect(text.contains("scheduled-example"))
        #expect(text.contains("201"))
    }
}

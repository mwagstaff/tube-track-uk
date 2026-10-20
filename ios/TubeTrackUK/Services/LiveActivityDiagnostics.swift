import Foundation
import OSLog

/// A bounded local history, independent of Console retention. Never pass payloads,
/// credentials, push tokens, or arbitrary error descriptions into this logger.
final class LiveActivityDiagnostics: @unchecked Sendable {
    static let shared = LiveActivityDiagnostics()
    private let queue = DispatchQueue(label: "dev.skynolimit.TubeTrackUK.diagnostics", qos: .utility)
    private let fileURL: URL
    private let logger = Logger(subsystem: "dev.skynolimit.TubeTrackUK", category: "Diagnostics")
    private static let retention: TimeInterval = 7 * 24 * 60 * 60
    private static let limit = 2000

    struct Event: Codable {
        let date: Date
        let name: String
        let fields: [String: String]
    }

    init(fileURL: URL = URL.applicationSupportDirectory
        .appending(path: "LiveActivityDiagnostics/events.json")) {
        self.fileURL = fileURL
    }

    static func record(_ name: String, _ fields: [String: String] = [:]) {
        shared.record(name, fields: fields)
    }

    func record(_ name: String, fields: [String: String] = [:], now: Date = .now) {
        // Defense in depth: callers use explicit metadata only. Truncate values
        // and reject credential-like keys before anything reaches disk.
        let safe = fields.filter { key, _ in
            !["token", "secret", "credential", "authorization", "payload", "body"].contains {
                key.lowercased().contains($0)
            }
        }.mapValues { String($0.prefix(256)) }
        queue.async { [self] in
            do {
                var events = try read(now: now)
                events.append(Event(date: now, name: String(name.prefix(100)), fields: safe))
                events = Array(events.suffix(Self.limit))
                try persist(events)
            } catch {
                logger.error("Could not persist diagnostics: \(String((error as NSError).code), privacy: .public)")
            }
        }
    }

    static func errorFields(_ error: Error) -> [String: String] {
        let error = error as NSError
        return ["errorDomain": error.domain, "errorCode": String(error.code)]
    }

    func export(metadata: [String: String], now: Date = .now) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let events = try read(now: now)
                    try persist(events) // Also expire old events when sharing.
                    struct Report: Encodable {
                        let generatedAt: Date
                        let metadata: [String: String]
                        let events: [Event]
                    }
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let directory = URL.temporaryDirectory.appending(path: "TubeTrackDiagnostics", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    // Keep exports bounded too; only the latest report is retained.
                    let url = directory.appending(path: "TubeTrack-diagnostics.json")
                    try encoder.encode(Report(generatedAt: now, metadata: metadata, events: events))
                        .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    continuation.resume(returning: url)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func read(now: Date) throws -> [Event] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let events = try JSONDecoder().decode([Event].self, from: Data(contentsOf: fileURL))
        return Array(events.filter { $0.date >= now.addingTimeInterval(-Self.retention) }.suffix(Self.limit))
    }

    private func persist(_ events: [Event]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        try JSONEncoder().encode(events).write(to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

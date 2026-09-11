import Foundation

actor SnapshotCache {
    private let directory: URL
    private let legacyDirectory: URL?

    init() {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appending(path: "TubeTrackUK/OfflineSnapshots", directoryHint: .isDirectory)
        let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        legacyDirectory = caches.appending(path: "TubeTrackUK", directoryHint: .isDirectory)
    }

    init(directory: URL, legacyDirectory: URL? = nil) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
    }

    func save<Value: Encodable & Sendable>(_ value: Value, named name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Offline snapshots must survive the system purging Library/Caches,
        // but this downloaded data does not need to occupy an iCloud backup.
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var directoryURL = directory
        try? directoryURL.setResourceValues(resourceValues)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: directory.appending(path: name), options: .atomic)
    }

    func load<Value: Codable & Sendable>(_ type: Value.Type, named name: String) throws -> Value {
        do {
            return try decode(type, at: directory.appending(path: name))
        } catch {
            guard let legacyDirectory,
                  let value = try? decode(type, at: legacyDirectory.appending(path: name)) else {
                throw error
            }
            // Migration is best effort: a write failure must not hide the
            // snapshot already available to a passenger without a connection.
            try? save(value, named: name)
            return value
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: data)
    }
}

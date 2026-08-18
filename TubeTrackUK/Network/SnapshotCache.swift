import Foundation

actor SnapshotCache {
    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appending(path: "TubeTrackUK", directoryHint: .isDirectory)
    }

    func save<Value: Encodable & Sendable>(_ value: Value, named name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: directory.appending(path: name), options: .atomic)
    }

    func load<Value: Decodable & Sendable>(_ type: Value.Type, named name: String) throws -> Value {
        let data = try Data(contentsOf: directory.appending(path: name))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: data)
    }
}


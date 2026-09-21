import Foundation

/// One rail stop point from the bundled network, without the geometry the
/// widgets never need. Co-located stop points share a `hubID`.
public struct StationIndexEntry: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let hubID: String
    public let name: String
    public let lineIDs: [TubeLineID]
    public let searchAliases: [String]

    public init(
        id: String,
        hubID: String,
        name: String,
        lineIDs: [TubeLineID],
        searchAliases: [String] = []
    ) {
        self.id = id
        self.hubID = hubID
        self.name = name
        self.lineIDs = lineIDs
        self.searchAliases = searchAliases
    }

    /// Passenger-facing name for constrained layouts: "Bank DLR Station"
    /// reads as "Bank" on a widget.
    public var displayName: String {
        for suffix in [" DLR Station", " Underground Station", " Rail Station", " Tram Stop"]
            where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}

/// A place a passenger would name — every stop point sharing one hub,
/// presented under its best-known name with the union of its lines.
public struct StationHub: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let stopIDs: [String]
    public let lineIDs: [TubeLineID]

    public init(id: String, name: String, stopIDs: [String], lineIDs: [TubeLineID]) {
        self.id = id
        self.name = name
        self.stopIDs = stopIDs
        self.lineIDs = lineIDs
    }
}

/// The slim station list bundled with the package (see
/// Tools/StationIndexBuilder). Loaded once per process.
public struct StationIndex: Sendable {
    public let schemaVersion: Int
    public let entries: [StationIndexEntry]
    private let entriesByID: [String: StationIndexEntry]
    private let entriesByHubID: [String: [StationIndexEntry]]

    public init(schemaVersion: Int, entries: [StationIndexEntry]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        entriesByHubID = Dictionary(grouping: entries, by: \.hubID)
    }

    public static let bundled: StationIndex = {
        guard let url = Bundle.module.url(forResource: "StationIndex", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(IndexFile.self, from: data) else {
            assertionFailure("StationIndex.json is missing from TubeTrackCore resources")
            return StationIndex(schemaVersion: 0, entries: [])
        }
        return StationIndex(schemaVersion: file.schemaVersion, entries: file.stations)
    }()

    public func entry(id: String) -> StationIndexEntry? {
        entriesByID[id]
    }

    /// The hub containing `id`, which may be either a stop point or hub ID.
    public func hub(containing id: String) -> StationHub? {
        let hubID = entriesByID[id]?.hubID ?? id
        guard let members = entriesByHubID[hubID], !members.isEmpty else { return nil }
        return Self.hub(id: hubID, members: members)
    }

    public var hubs: [StationHub] {
        entriesByHubID.map { Self.hub(id: $0.key, members: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Hubs matching `query`, best match first. Mirrors the app's station
    /// search so the widget picker and the in-app sheet agree.
    public func search(_ query: String, limit: Int? = nil) -> [StationHub] {
        let normalizedQuery = Self.normalized(query)
        let queryTokens = normalizedQuery.split(separator: " ").map(String.init)

        let ranked = entries.compactMap { entry -> (entry: StationIndexEntry, score: Int)? in
            let name = Self.normalized(entry.name)
            let aliases = entry.searchAliases.map(Self.normalized)
            let searchableText = ([name] + aliases).joined(separator: " ")
            guard queryTokens.allSatisfy(searchableText.contains) else { return nil }

            let score: Int
            if normalizedQuery.isEmpty || name == normalizedQuery {
                score = 0
            } else if name.hasPrefix(normalizedQuery) {
                score = 1
            } else if name.split(separator: " ").contains(where: { $0.hasPrefix(normalizedQuery) }) {
                score = 2
            } else if name.contains(normalizedQuery) {
                score = 3
            } else if aliases.contains(normalizedQuery) {
                score = 4
            } else if aliases.contains(where: { $0.hasPrefix(normalizedQuery) }) {
                score = 5
            } else {
                score = 6
            }
            return (entry, score)
        }
        .sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            let nameOrder = $0.entry.name.localizedStandardCompare($1.entry.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.entry.id < $1.entry.id
        }

        var orderedHubIDs: [String] = []
        var seen = Set<String>()
        for match in ranked where seen.insert(match.entry.hubID).inserted {
            orderedHubIDs.append(match.entry.hubID)
        }
        let hubs = orderedHubIDs.compactMap { hub(containing: $0) }
        guard let limit else { return hubs }
        return Array(hubs.prefix(limit))
    }

    private static func hub(id: String, members: [StationIndexEntry]) -> StationHub {
        // Prefer the plain name ("Bank") over a suffixed one ("Bank DLR Station").
        let representative = members.min {
            if $0.name.count != $1.name.count { return $0.name.count < $1.name.count }
            return $0.id < $1.id
        }!
        var lineIDs: [TubeLineID] = []
        for member in members.sorted(by: { $0.id < $1.id }) {
            for lineID in member.lineIDs where !lineIDs.contains(lineID) {
                lineIDs.append(lineID)
            }
        }
        return StationHub(
            id: id,
            name: representative.displayName,
            stopIDs: members.map(\.id).sorted(),
            lineIDs: lineIDs
        )
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private struct IndexFile: Decodable {
        let schemaVersion: Int
        let stations: [StationIndexEntry]
    }
}

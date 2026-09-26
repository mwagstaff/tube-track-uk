import Foundation
import Observation

struct FavouriteStop: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case station, pier, cableCarTerminal }
    let stopId: String
    let name: String
    let kind: Kind
    var id: String { "\(kind.rawValue):\(stopId)" }
    static func station(_ station: TubeStation) -> Self {
        .init(stopId: station.hubID ?? station.id, name: station.name, kind: .station)
    }
    var symbol: String {
        switch kind { case .station: "tram.fill"; case .pier: "ferry.fill"; case .cableCarTerminal: "cablecar.fill" }
    }
    static func terminal(_ terminal: CableCarTerminal) -> Self { .init(stopId: terminal.id, name: terminal.name, kind: .cableCarTerminal) }
    static func pier(_ pier: RiverPier) -> Self { .init(stopId: pier.id, name: pier.name, kind: .pier) }
}

@MainActor @Observable
final class FavouriteStopsStore {
    private(set) var stops: [FavouriteStop]
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "favouriteStops.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stops = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([FavouriteStop].self, from: $0) } ?? []
    }

    func contains(_ stop: FavouriteStop) -> Bool { stops.contains { $0.id == stop.id } }
    func toggle(_ stop: FavouriteStop) {
        if contains(stop) { stops.removeAll { $0.id == stop.id } }
        else { stops.append(stop) }
        stops.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let data = try? JSONEncoder().encode(stops) { defaults.set(data, forKey: Self.key) }
    }
}

import CoreLocation
import Foundation
import Observation

@MainActor @Observable
final class DepartureBoardStore {
    private(set) var favourites: [DepartureFavourite]
    private(set) var views: [String: DepartureFavourite]
    private(set) var boards: [DepartureBoardRequest: CustomDepartureBoard] = [:]
    private(set) var errors: [DepartureBoardRequest: String] = [:]
    private(set) var loading: Set<DepartureBoardRequest> = []
    var tab: String { didSet { defaults.set(tab, forKey: "departures.tab") } }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: TubeTrackAPIClient
    @ObservationIgnored private var fetched: [DepartureBoardRequest: Date] = [:]
    @ObservationIgnored private var flights: [DepartureBoardRequest: Task<CustomDepartureBoard, Error>] = [:]

    init(defaults: UserDefaults = .standard, client: TubeTrackAPIClient = TubeTrackAPIClient()) {
        self.defaults = defaults; self.client = client
        let saved: [DepartureFavourite]
        if let data = defaults.data(forKey: "departures.favourites.v1") {
            saved = (try? JSONDecoder().decode([DepartureFavourite].self, from: data)) ?? []
        } else {
            let legacy = defaults.data(forKey: "favouriteStops.v1")
                .flatMap { try? JSONDecoder().decode([FavouriteStop].self, from: $0) } ?? []
            saved = legacy.filter { $0.kind != .cableCarTerminal }.map { stop in
                let id = DepartureStop.bundled.first { $0.id == stop.stopId || $0.stopIDs.contains(stop.stopId) }?.id ?? stop.stopId
                return DepartureFavourite(outbound: .init(originID: id))
            }
            if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "departures.favourites.v1") }
        }
        favourites = saved
        views = defaults.data(forKey: "departures.views.v1")
            .flatMap { try? JSONDecoder().decode([String: DepartureFavourite].self, from: $0) } ?? [:]
        tab = defaults.string(forKey: "departures.tab") ?? (saved.isEmpty ? "nearby" : "favourites")
    }

    func save(_ favourite: DepartureFavourite) {
        if let index = favourites.firstIndex(where: { $0.id == favourite.id }) { favourites[index] = favourite }
        else { favourites.append(favourite) }
        persist()
    }
    func remove(_ id: UUID) { favourites.removeAll { $0.id == id }; persist() }
    func saveView(_ view: DepartureFavourite, key: String) { views[key] = view; persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(favourites) { defaults.set(data, forKey: "departures.favourites.v1") }
        if let data = try? JSONEncoder().encode(views) { defaults.set(data, forKey: "departures.views.v1") }
    }

    func refresh(_ request: DepartureBoardRequest, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        if !force, let last = fetched[request], Date.now.timeIntervalSince(last) < 25 { return }
        if let flight = flights[request] { _ = try? await flight.value; return }
        loading.insert(request)
        let flight = Task { [client] in
            try await client.get("/api/v1/departure-board", queryItems: [
                .init(name: "origin", value: request.originID),
                .init(name: "destinations", value: request.destinationIDs.joined(separator: ",")),
                .init(name: "lines", value: request.lineIDs.joined(separator: ",")),
                .init(name: "direction", value: request.direction)
            ], forceRefresh: force, as: CustomDepartureBoard.self)
        }
        flights[request] = flight
        defer { loading.remove(request); flights.removeValue(forKey: request) }
        do {
            let board = try await withTaskCancellationHandler { try await flight.value } onCancel: { flight.cancel() }
            try Task.checkCancellation()
            boards[request] = board; errors.removeValue(forKey: request); fetched[request] = .now
            if boards.count > 80 {
                let expired = fetched.sorted { $0.value < $1.value }.prefix(boards.count - 80).map(\.key)
                for key in expired { boards.removeValue(forKey: key); fetched.removeValue(forKey: key); errors.removeValue(forKey: key) }
            }
        } catch {
            if !Task.isCancelled { errors[request] = "Live departures temporarily unavailable. Retrying…" }
        }
    }
}

extension TubeAppState {
    var departureStops: [DepartureStop] {
        DepartureStop.bundled + river.network.piers.map {
            DepartureStop(id: $0.id, name: $0.name, latitude: $0.latitude, longitude: $0.longitude,
                          stopIDs: [$0.id], lineIDs: $0.lineIds, mode: "river")
        }
    }
    func departureStop(id: String) -> DepartureStop? {
        departureStops.first { $0.id == id || $0.stopIDs.contains(id) }
    }
}

enum DepartureLocation {
    static func distances(stops: [DepartureStop], location: CLLocation?) -> [String: Double] {
        guard let location, location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 10 * 60 else { return [:] }
        return Dictionary(uniqueKeysWithValues: stops.map {
            ($0.id, location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)))
        })
    }
}

struct DepartureServiceOption: Identifiable, Sendable {
    let id: String
    let name: String

    // Map artwork/status identifiers to the National Rail feed's operator codes.
    static let operatorCodes = ["avanti-west-coast": "VT", "c2c": "CC", "chiltern-railways": "CH",
        "crosscountry": "XC", "east-midlands-railway": "EM", "gatwick-express": "GX",
        "grand-central": "GC", "great-northern": "GN", "great-western-railway": "GW",
        "greater-anglia": "LE", "heathrow-express": "HX", "hull-trains": "HT",
        "london-north-eastern-railway": "GR", "lumo": "LD", "south-western-railway": "SW",
        "southeastern": "SE", "southeastern-high-speed": "SE", "southern": "SN",
        "west-midlands-trains": "LM", "london-northwestern-railway": "LM"]

    private static let mapServicesByStopID: [String: [Self]] = {
        var result: [String: [Self]] = [:]
        for route in NationalRailMap.bundled.routes {
            let option = Self(id: serviceID(route.operatorID), name: route.name)
            for id in [route.fromStationID, route.toStationID] {
                if !(result[id] ?? []).contains(where: { $0.id == option.id }) {
                    result[id, default: []].append(option)
                }
            }
        }
        return result
    }()

    static func mappedRailwayServices(for stop: DepartureStop) -> [Self] {
        stationAliases(for: stop).flatMap { mapServicesByStopID[$0] ?? [] }
    }

    static func stationAliases(for stop: DepartureStop) -> [String] {
        let codes = Set(stop.railCodes)
        return stop.stopIDs + [stop.id] + NationalRailStations.codesByStopID.compactMap { id, values in
            codes.isDisjoint(with: values) ? nil : id
        }
    }

    static func selectedID(options: [Self], selected: String?, preferred: String?) -> String? {
        let requested = selected ?? preferred.map(serviceID)
        if let requested, options.contains(where: { $0.id == requested }) { return requested }
        return options.first?.id
    }

    static func serviceID(_ id: String) -> String {
        if id == "thameslink-extension" { return "thameslink" }
        return operatorCodes[id].map { "national-rail:\($0)" } ?? id
    }
}


extension TubeAppState {
    func journeyStation(for stop: DepartureStop) -> TubeStation? {
        let aliases = Set([stop.id] + stop.stopIDs)
        return graph?.stations.first {
            aliases.contains($0.id) || $0.hubID.map(aliases.contains) == true
        }
    }

    @discardableResult
    func prepareJourney(at stop: DepartureStop, asOrigin: Bool) -> Bool {
        guard let station = journeyStation(for: stop) else { return false }
        if asOrigin {
            journeyPlanner.from = station
            if journeyPlanner.hasSameStation { journeyPlanner.to = nil }
        } else {
            journeyPlanner.to = station
            if journeyPlanner.hasSameStation { journeyPlanner.from = nil }
        }
        return true
    }
}

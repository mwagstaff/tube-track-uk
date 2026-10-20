import Foundation

public struct RailCallingPoint: Decodable, Sendable {
    public let locationName: String
    public let crs: String
    public let st: String?
    public let et: String?
    public let at: String?
    public let isCancelled: Bool?

    public var timing: String {
        let booked = st.flatMap { $0.isEmpty ? nil : $0 } ?? "Time unavailable"
        if isCancelled == true || et?.lowercased() == "cancelled" { return "\(booked) · Cancelled" }
        if let at, !at.isEmpty { return "\(booked) · Actual \(at)" }
        guard let et, !et.isEmpty else { return "\(booked) · Live time unavailable" }
        if ["on time", "ontime"].contains(et.lowercased()) { return "\(booked) · On time" }
        if et.lowercased() == "delayed" { return "\(booked) · Delayed" }
        return "\(booked) · Expected \(et)"
    }
}

public struct RailCallingPointGroup: Decodable, Sendable {
    public let callingPoint: [RailCallingPoint]
    public let serviceChangeRequired: Bool?
    public let assocIsCancelled: Bool?
}

public struct RailCallingPoints: Decodable, Sendable {
    public let locationName: String
    public let crs: String
    public let std: String?
    public let sta: String?
    public let etd: String?
    public let eta: String?
    public let atd: String?
    public let ata: String?
    public let isCancelled: Bool?
    public let subsequentCallingPoints: [RailCallingPointGroup]?

    public var boardingPoint: RailCallingPoint {
        RailCallingPoint(locationName: locationName, crs: crs, st: std ?? sta,
                         et: etd ?? eta, at: atd ?? ata, isCancelled: isCancelled)
    }
}

public extension TfLArrivalPrediction {
    var supportsCallingPoints: Bool { lineId.hasPrefix("national-rail:") || lineId == "thameslink" }

    /// Keep the entire provider ID, including any colons it contains.
    var railServiceReference: (station: String, serviceID: String)? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "national-rail", parts[1].count == 3,
              !parts[2].isEmpty else { return nil }
        return (String(parts[1]), String(parts[2]))
    }
}

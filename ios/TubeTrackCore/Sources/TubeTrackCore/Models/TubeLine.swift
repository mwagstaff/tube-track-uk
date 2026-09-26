import SwiftUI

public enum TubeLineID: String, Codable, CaseIterable, Identifiable, Sendable {
    case bakerloo
    case central
    case circle
    case district
    case hammersmithCity = "hammersmith-city"
    case jubilee
    case metropolitan
    case northern
    case piccadilly
    case victoria
    case waterlooCity = "waterloo-city"
    case dlr
    case elizabeth
    case tram
    case liberty
    case lioness
    case mildmay
    case suffragette
    case weaver
    case windrush

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bakerloo: "Bakerloo"
        case .central: "Central"
        case .circle: "Circle"
        case .district: "District"
        case .hammersmithCity: "Hammersmith & City"
        case .jubilee: "Jubilee"
        case .metropolitan: "Metropolitan"
        case .northern: "Northern"
        case .piccadilly: "Piccadilly"
        case .victoria: "Victoria"
        case .waterlooCity: "Waterloo & City"
        case .dlr: "DLR"
        case .elizabeth: "Elizabeth line"
        case .tram: "London Trams"
        case .liberty: "Liberty line"
        case .lioness: "Lioness line"
        case .mildmay: "Mildmay line"
        case .suffragette: "Suffragette line"
        case .weaver: "Weaver line"
        case .windrush: "Windrush line"
        }
    }

    /// Short labels for constrained layouts (small widgets, accented
    /// rendering) where line colours may be unavailable.
    public var shortCode: String {
        switch self {
        case .bakerloo: "Bak"
        case .central: "Cen"
        case .circle: "Cir"
        case .district: "Dis"
        case .hammersmithCity: "H&C"
        case .jubilee: "Jub"
        case .metropolitan: "Met"
        case .northern: "Nor"
        case .piccadilly: "Pic"
        case .victoria: "Vic"
        case .waterlooCity: "W&C"
        case .dlr: "DLR"
        case .elizabeth: "Eliz"
        case .tram: "Tram"
        case .liberty: "Lib"
        case .lioness: "Lio"
        case .mildmay: "Mil"
        case .suffragette: "Suf"
        case .weaver: "Wea"
        case .windrush: "Win"
        }
    }

    /// TfL's familiar ordering in compact status views.
    public static let widgetDisplayOrder: [Self] = [
        .bakerloo, .central, .circle, .district, .hammersmithCity, .jubilee,
        .metropolitan, .northern, .piccadilly, .victoria, .waterlooCity,
        .dlr, .elizabeth,
        .liberty, .lioness, .mildmay, .suffragette, .weaver, .windrush,
        .tram,
    ]

    public var widgetDisplayRank: Int {
        Self.widgetDisplayOrder.firstIndex(of: self) ?? Self.widgetDisplayOrder.count
    }

    /// A readable name for the three-row Watch widget.
    public var watchShortName: String {
        switch self {
        case .hammersmithCity: "H&C"
        case .waterlooCity: "W&C"
        case .elizabeth: "Elizabeth"
        case .tram: "Trams"
        default: displayName.replacingOccurrences(of: " line", with: "")
        }
    }

    public static var undergroundCases: [Self] { allCases.filter(\.isUnderground) }

    public static var liveTrainFilterCases: [Self] {
        allCases
            .filter(\.supportsEstimatedTrains)
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    public var isUnderground: Bool {
        switch self {
        case .bakerloo, .central, .circle, .district, .hammersmithCity, .jubilee,
             .metropolitan, .northern, .piccadilly, .victoria, .waterlooCity:
            true
        case .dlr, .elizabeth, .tram, .liberty, .lioness, .mildmay, .suffragette,
             .weaver, .windrush:
            false
        }
    }

    public var modeName: String {
        switch self {
        case .dlr: "dlr"
        case .elizabeth: "elizabeth-line"
        case .tram: "tram"
        case .liberty, .lioness, .mildmay, .suffragette, .weaver, .windrush: "overground"
        default: "tube"
        }
    }

    public var usesParallelSchematicStroke: Bool { !isUnderground }

    public var supportsEstimatedTrains: Bool {
        true
    }

    public var liveTrainMarkerAssetName: String {
        switch self {
        case .dlr:
            "TrainMarkerDLR"
        case .tram:
            "TrainMarkerTram"
        case .elizabeth, .liberty, .lioness, .mildmay, .suffragette, .weaver, .windrush:
            "TrainMarkerOverground"
        case .bakerloo, .central, .circle, .district, .hammersmithCity, .jubilee,
             .metropolitan, .northern, .piccadilly, .victoria, .waterlooCity:
            "TrainMarkerTube"
        }
    }
}

extension Color {
    public static let tubeBlue = Color(red: 0.04, green: 0.17, blue: 0.43)

    public static func tubeLine(_ line: TubeLineID) -> Color {
        switch line {
        case .bakerloo: Color(red: 0.55, green: 0.27, blue: 0.07)
        case .central: Color(red: 0.88, green: 0.12, blue: 0.14)
        case .circle: Color(red: 1.00, green: 0.78, blue: 0.05)
        case .district: Color(red: 0.00, green: 0.49, blue: 0.22)
        case .hammersmithCity: Color(red: 0.95, green: 0.59, blue: 0.70)
        case .jubilee: Color(red: 0.48, green: 0.53, blue: 0.55)
        case .metropolitan: Color(red: 0.60, green: 0.00, blue: 0.35)
        case .northern: .black
        case .piccadilly: Color(red: 0.00, green: 0.10, blue: 0.65)
        case .victoria: Color(red: 0.00, green: 0.63, blue: 0.88)
        case .waterlooCity: Color(red: 0.46, green: 0.82, blue: 0.75)
        case .dlr: Color(red: 0.00, green: 0.686, blue: 0.678)
        case .elizabeth: Color(red: 0.376, green: 0.224, blue: 0.620)
        case .tram: Color(red: 105.0 / 255.0, green: 194.0 / 255.0, blue: 47.0 / 255.0)
        case .liberty: Color(red: 0.310_699, green: 0.366_104, blue: 0.385_895)
        case .lioness: Color(red: 0.971_756, green: 0.613_312, blue: 0.056_473)
        case .mildmay: Color(red: 0.139_847, green: 0.524_109, blue: 0.794_968)
        case .suffragette: Color(red: 0.350_006, green: 0.764_206, blue: 0.392_731)
        case .weaver: Color(red: 0.690_094, green: 0.135_376, blue: 0.496_674)
        case .windrush: Color(red: 0.929_001, green: 0.098_816, blue: 0.181_976)
        }
    }
}

import SwiftUI

enum TubeLineID: String, Codable, CaseIterable, Identifiable, Sendable {
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
    case liberty
    case lioness
    case mildmay
    case suffragette
    case weaver
    case windrush

    var id: String { rawValue }

    var displayName: String {
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
        case .liberty: "Liberty line"
        case .lioness: "Lioness line"
        case .mildmay: "Mildmay line"
        case .suffragette: "Suffragette line"
        case .weaver: "Weaver line"
        case .windrush: "Windrush line"
        }
    }

    static var undergroundCases: [Self] { allCases.filter(\.isUnderground) }

    var isUnderground: Bool {
        switch self {
        case .bakerloo, .central, .circle, .district, .hammersmithCity, .jubilee,
             .metropolitan, .northern, .piccadilly, .victoria, .waterlooCity:
            true
        case .dlr, .elizabeth, .liberty, .lioness, .mildmay, .suffragette,
             .weaver, .windrush:
            false
        }
    }

    var modeName: String {
        switch self {
        case .dlr: "dlr"
        case .elizabeth: "elizabeth-line"
        case .liberty, .lioness, .mildmay, .suffragette, .weaver, .windrush: "overground"
        default: "tube"
        }
    }

    var usesParallelSchematicStroke: Bool { !isUnderground }

    var supportsEstimatedTrains: Bool {
        switch self {
        case .dlr: false
        default: true
        }
    }
}

extension Color {
    static let tubeBlue = Color(red: 0.04, green: 0.17, blue: 0.43)

    static func tubeLine(_ line: TubeLineID) -> Color {
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
        case .liberty: Color(red: 0.310_699, green: 0.366_104, blue: 0.385_895)
        case .lioness: Color(red: 0.971_756, green: 0.613_312, blue: 0.056_473)
        case .mildmay: Color(red: 0.139_847, green: 0.524_109, blue: 0.794_968)
        case .suffragette: Color(red: 0.350_006, green: 0.764_206, blue: 0.392_731)
        case .weaver: Color(red: 0.690_094, green: 0.135_376, blue: 0.496_674)
        case .windrush: Color(red: 0.929_001, green: 0.098_816, blue: 0.181_976)
        }
    }
}

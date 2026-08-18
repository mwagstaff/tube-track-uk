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
        }
    }
}


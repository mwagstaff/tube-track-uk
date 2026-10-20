import SwiftUI

/// A shared, shape-and-colour status cue for individual National Rail and Thameslink trains.
public struct RailDepartureStatusIcon: View {
    public let status: RailServiceStatus

    public init(status: RailServiceStatus) {
        self.status = status
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(minWidth: 20)
            .fixedSize()
            .accessibilityLabel(status.departureAccessibilityLabel)
    }

    private var symbol: String {
        switch status {
        case .onTime, .unknown: "checkmark.circle.fill"
        case .delayed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .onTime, .unknown: .green
        case .delayed: .orange
        case .cancelled: .red
        }
    }
}

extension RailServiceStatus {
    // A missing/unknown provider status means no disruption has been reported.
    // Keep the raw status intact for forecast handling, but present it as on time.

    public var departureAccessibilityLabel: String {
        switch self {
        case .onTime, .unknown: "On time"
        case .delayed: "Delayed"
        case .cancelled: "Cancelled"
        }
    }
}

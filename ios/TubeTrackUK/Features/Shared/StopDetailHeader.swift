import SwiftUI

/// Shared action placement for station and pier selection cards.
struct StopDetailHeader<Directions: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let stop: FavouriteStop
    let closeHint: String
    let onClose: () -> Void
    @ViewBuilder let directions: () -> Directions

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 4) {
                    title
                    Spacer(minLength: 4)
                    closeButton
                }
                HStack(spacing: 4) {
                    FavouriteStopButton(stop: stop)
                    directions()
                    Spacer(minLength: 0)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 4) {
                title
                Spacer(minLength: 4)
                actions
            }
        }
    }

    private var title: some View {
        Text(stop.name)
            .font(.appHeadline())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var actions: some View {
        FavouriteStopButton(stop: stop)
        directions()
        closeButton
    }

    private var closeButton: some View {
        Button("Close", systemImage: "xmark.circle.fill", action: onClose)
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .font(.appTitle2())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
            .buttonStyle(.plain)
            .accessibilityHint(closeHint)
    }
}

struct DepartureTrackButton: View {
    let isTracking: Bool
    let boardName: String
    let action: () -> Void

    var body: some View {
        DepartureBoardActionButton(
            title: isTracking ? "Tracking" : "Track",
            systemImage: isTracking ? "dot.radiowaves.left.and.right" : "pin",
            isActive: isTracking,
            action: action
        )
        .accessibilityLabel("\(isTracking ? "Stop tracking" : "Track") \(boardName) departures")
        .accessibilityHint(isTracking
            ? "Removes the departure board from the Lock Screen"
            : "Shows this departure board on the Lock Screen")
    }
}

/// Keeps the adjacent Schedule and Track actions visually identical.
struct DepartureBoardActionButton: View {
    let title: String
    let systemImage: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.appCaption(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .foregroundStyle(isActive ? Color.departureAccent : .secondary)
    }
}

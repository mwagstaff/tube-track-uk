import CoreLocation
import SwiftUI

struct MapCurrentLocationButton: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(UserLocationProvider.self) private var locationProvider
    @State private var awaitingLocation = false
    @State private var showsError = false
    let interactionGeneration: Int
    let onFocus: (CLLocation) -> Void

    var body: some View {
        Button {
            if let location = locationProvider.location,
               MapLocationFocusPolicy.isUsable(location) {
                onFocus(location)
            } else {
                awaitingLocation = true
            }
            locationProvider.requestLocation()
            if locationProvider.needsSettingsPermission {
                awaitingLocation = false
                showsError = true
            }
        } label: {
            Group {
                if awaitingLocation && locationProvider.isRequesting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "location.fill")
                        .font(.appHeadline(.semibold))
                }
            }
            .foregroundStyle(Color.blue)
            .frame(width: MapDockMetrics.controlSize, height: MapDockMetrics.controlSize)
            .glassEffect(.regular.interactive(), in: .circle)
            .frame(width: 60, height: 60)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(appState.graph == nil || awaitingLocation)
        .accessibilityLabel("Current location")
        .accessibilityHint("Centers the map on you and shows the closest station if enabled")
        .onChange(of: locationProvider.location) { _, location in
            guard awaitingLocation, let location else { return }
            awaitingLocation = false
            onFocus(location)
        }
        .onChange(of: locationProvider.isRequesting) { _, requesting in
            guard awaitingLocation, !requesting else { return }
            awaitingLocation = false
            showsError = locationProvider.needsSettingsPermission
                || locationProvider.errorMessage != nil
        }
        .onChange(of: interactionGeneration) { awaitingLocation = false }
        .onDisappear { awaitingLocation = false }
        .alert("Location unavailable", isPresented: $showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(locationProvider.needsSettingsPermission
                ? "Allow location access in Settings to zoom to your position."
                : locationProvider.errorMessage ?? "Please try again.")
        }
    }
}

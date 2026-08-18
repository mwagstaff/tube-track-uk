import SwiftUI

struct AboutScreen: View {
    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            TubeTrackMark()
                            Text("Beautiful. Informative. Real-time.")
                                .font(.headline)
                            Text("A modern, independent live view of the London Underground.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Developer") {
                    Link(destination: URL(string: "https://skynolimit.dev")!) {
                        Label("SkyNoLimit", systemImage: "safari")
                    }
                }

                Section("Data Sources") {
                    Link(destination: URL(string: "https://tfl.gov.uk/info-for/open-data-users/")!) {
                        Label("Data provided by Transport for London", systemImage: "tram.fill")
                    }
                    Text("Live status, arrival predictions, station topology and planned works use TfL open data. Train markers are estimates interpolated from predictions; they are not GPS locations.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Mapping") {
                    Label("Apple MapKit", systemImage: "map")
                    Link(destination: URL(string: "https://www.openstreetmap.org/copyright")!) {
                        Label("© OpenStreetMap contributors", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    }
                    Text("The Real World view preserves Apple’s map attribution. Underground routes use an offline OSM railway graph so lines and train estimates follow the mapped track alignment instead of station-to-station chords.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Privacy & Independence") {
                    Label("No account or location required", systemImage: "hand.raised.fill")
                    Text("TubeTrack UK is independent and is not affiliated with or endorsed by Transport for London.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Version") {
                    LabeledContent("TubeTrack UK", value: version)
                    Text("Made for London by SkyNoLimit")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("About")
        }
    }
}

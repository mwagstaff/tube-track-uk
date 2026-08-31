import SwiftUI

struct AboutScreen: View {
    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        List {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Text("TubeTrack UK")
                                .font(.headline.weight(.bold))
                            Text("It's not just the Internet that's a series of tubes.")
                                .font(.headline)
                            Text("A live view of London’s Tube, Overground and tram network.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    Link(destination: URL(string: "https://skynolimit.dev")!) {
                        Label("SkyNoLimit", systemImage: "safari")
                    }
                } header: {
                    AppBackgroundSectionHeader(title: "Developer")
                }

                Section {
                    Link(destination: URL(string: "https://tfl.gov.uk/info-for/open-data-users/")!) {
                        Label("Data provided by Transport for London", systemImage: "tram.fill")
                    }
                    Text("Live status, arrival predictions, station topology and planned works use TfL open data. Train markers are estimates interpolated from predictions; they are not GPS locations.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    AppBackgroundSectionHeader(title: "Data Sources")
                }

                Section {
                    Label("Apple MapKit", systemImage: "map")
                    Link(destination: URL(string: "https://www.openstreetmap.org/copyright")!) {
                        Label("© OpenStreetMap contributors", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    }
                    Text("The real-world map mode preserves Apple’s map attribution. Tube, Overground and tram routes use an offline OSM railway graph so lines and supported train estimates follow mapped track alignments instead of station-to-station chords.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    AppBackgroundSectionHeader(title: "Mapping")
                }

                Section {
                    Label("No account or personal data required", systemImage: "hand.raised.fill")
                    Text("TubeTrack UK is independent and is not affiliated with or endorsed by Transport for London. We think TfL is pretty great, though. Thanks for sharing your data! ❤️")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    AppBackgroundSectionHeader(title: "Privacy & Independence")
                }

                Section {
                    LabeledContent("TubeTrack UK", value: version)
                    Text("Made for London by SkyNoLimit")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    AppBackgroundSectionHeader(title: "Version")
                }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .appBackgroundPage()
    }
}

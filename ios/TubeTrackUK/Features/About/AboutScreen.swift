import SwiftUI

struct AboutScreen: View {
    @Environment(TubeAppState.self) private var appState
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
                                .font(.appHeadline(.bold))
                            Text("A live view of London’s Tube, Overground and tram network.")
                                .font(.appSubheadline())
                                .foregroundStyle(.white.opacity(0.9))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    Link(destination: URL(string: "https://skynolimit.dev")!) {
                        Label("SkyNoLimit", systemImage: "safari")
                    }
                    .requiresNetwork(appState.isOffline)
                } header: {
                    AppBackgroundSectionHeader(title: "Developer")
                }

                Section {
                    Link(destination: URL(string: "https://tfl.gov.uk/info-for/open-data-users/")!) {
                        Label("Powered by TfL Open Data", systemImage: "tram.fill")
                    }
                    .requiresNetwork(appState.isOffline)
                    Text("Live status, arrival predictions, station topology and planned works use TfL open data. Train markers are estimates interpolated from predictions; they are not GPS locations.")
                        .font(.appFootnote())
                        .foregroundStyle(.secondary)
                } header: {
                    AppBackgroundSectionHeader(title: "Data Sources")
                }

                Section {
                    Label("Apple MapKit", systemImage: "map")
                    Link(destination: URL(string: "https://www.openstreetmap.org/copyright")!) {
                        Label("© OpenStreetMap contributors", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    }
                    .requiresNetwork(appState.isOffline)
                    Text("The real-world map mode preserves Apple’s map attribution. Tube, Overground and tram routes use an offline OSM railway graph so lines and supported train estimates follow mapped track alignments instead of station-to-station chords.")
                        .font(.appFootnote())
                        .foregroundStyle(.secondary)
                } header: {
                    AppBackgroundSectionHeader(title: "Mapping")
                }

                Section {
                    Label("No account or personal data required", systemImage: "hand.raised.fill")
                    Text("TubeTrack UK is independent and is not affiliated with or endorsed by TfL, although we think they're pretty great and thank them for sharing their data. ")
                        .font(.appFootnote())
                        .foregroundStyle(.secondary)
                } header: {
                    AppBackgroundSectionHeader(title: "Privacy & Independence")
                }

                Section {
                    LabeledContent("TubeTrack UK", value: version)
                    Text("Made for London by SkyNoLimit")
                        .font(.appFootnote())
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

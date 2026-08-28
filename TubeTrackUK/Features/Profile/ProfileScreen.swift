import SwiftUI

struct ProfileScreen: View {
    @Environment(TubeAppState.self) private var appState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AboutScreen()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }

                    NavigationLink {
                        TfLAPIKeyScreen()
                    } label: {
                        HStack {
                            Label("TfL API key", systemImage: "key.fill")
                            Spacer()
                            if appState.isTfLAPIKeyConfigured {
                                Text("Added")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Profile")
        }
    }
}

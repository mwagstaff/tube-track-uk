import SwiftUI

struct ProfileScreen: View {
    @Environment(TubeAppState.self) private var appState
    #if DEBUG
    @Environment(AppBackgroundImageStore.self) private var backgroundImageStore
    #endif

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
                                    .font(.appSubheadline())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                #if DEBUG
                Section {
                    Button {
                        backgroundImageStore.advanceToNextImage()
                    } label: {
                        Label("Show next image", systemImage: "photo.on.rectangle.angled")
                    }
                } header: {
                    Text("Background image debugging")
                }
                #endif
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(.secondarySystemBackground), for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
        }
    }
}

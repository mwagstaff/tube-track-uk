import SwiftUI

struct ProfileScreen: View {
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

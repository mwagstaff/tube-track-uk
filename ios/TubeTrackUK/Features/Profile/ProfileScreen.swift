import SwiftUI

private enum ProfileDestination: Hashable {
    case about
}

struct ProfileScreen: View {
    @Binding var showsImageBackground: Bool
    @State private var navigationPath: [ProfileDestination] = []

    #if DEBUG
    @Environment(AppBackgroundImageStore.self) private var backgroundImageStore
    #endif

    var body: some View {
        ZStack {
            if showsImageBackground {
                AppBackgroundImage(scrimOpacity: 0.34)
            }

            NavigationStack(path: $navigationPath) {
                List {
                    Section {
                        NavigationLink(value: ProfileDestination.about) {
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
                .navigationDestination(for: ProfileDestination.self) { destination in
                    switch destination {
                    case .about:
                        AboutScreen()
                    }
                }
            }
        }
        .onAppear {
            updateImageBackgroundState()
        }
        .onChange(of: navigationPath) {
            updateImageBackgroundState()
        }
        .onDisappear {
            showsImageBackground = false
        }
    }

    private func updateImageBackgroundState() {
        showsImageBackground = navigationPath.last == .about
    }
}

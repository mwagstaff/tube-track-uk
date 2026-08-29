import SwiftUI

struct ProfileScreen: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(AppBackgroundImageStore.self) private var backgroundImageStore

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

                #if DEBUG
                Section {
                    Button {
                        backgroundImageStore.advanceToNextImage()
                    } label: {
                        Label("Show next image", systemImage: "photo.on.rectangle.angled")
                    }
                } header: {
                    AppBackgroundSectionHeader(title: "Background image debugging")
                }
                #endif
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if let attribution = backgroundImageStore.selectedImageAttribution {
                    Link(destination: attribution.sourceURL) {
                        Text("Image courtesy of \(attribution.artistName), \(attribution.sourceName)")
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.88))
                            .underline(color: .white.opacity(0.55))
                            .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
                            .padding(.horizontal, 20)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 20)
                    .accessibilityHint("Opens this photograph on Unsplash")
                }
            }
            .appBackgroundPage()
            .toolbarBackground(Color(.secondarySystemBackground), for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
        }
    }
}

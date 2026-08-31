import SwiftUI

struct TfLAPIKeyScreen: View {
    @Environment(TubeAppState.self) private var appState

    @State private var draftKey = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let portalURL = URL(string: "https://api-portal.tfl.gov.uk/profile")!

    var body: some View {
        Form {
            if appState.isTfLAPIKeyConfigured {
                configuredSection
            } else {
                registrationSection
            }

            keyEntrySection

            if appState.hasUserProvidedTfLAPIKey {
                Section {
                    Button("Remove API key", role: .destructive) {
                        Task { await removeKey() }
                    }
                    .disabled(isSaving)
                } footer: {
                    Text("Without a key, TubeTrack UK returns to TfL’s standard request allowance.")
                }
            }
        }
        .navigationTitle("TfL API key")
        .navigationBarTitleDisplayMode(.inline)
        .appBackgroundPage()
        .alert("Couldn’t update API key", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private var configuredSection: some View {
        Section {
            Label("API key added", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Your key is stored securely on this device and is included as the app_key query parameter on TfL requests.")
                .font(.appFootnote())
                .foregroundStyle(.secondary)
        }
    }

    private var registrationSection: some View {
        Section {
            Text("TfL allows standard access at up to 50 requests per minute. A free API key raises that allowance to up to 500 requests per minute.")

            VStack(alignment: .leading, spacing: 10) {
                instruction(1, "Register for a TfL API Portal account.")
                instruction(2, "Add a free subscription to the “500 Requests per min” product.")
                instruction(3, "Copy the API key from your profile and enter it below.")
            }
            .font(.appSubheadline())

            Link(destination: portalURL) {
                Label("Open TfL API Portal", systemImage: "arrow.up.right.square")
            }
        } header: {
            AppBackgroundSectionHeader(title: "Get a free key")
        }
    }

    private var keyEntrySection: some View {
        Section {
            SecureField("Paste your TfL API key", text: $draftKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .submitLabel(.done)
                .onSubmit {
                    guard canSave else { return }
                    Task { await saveKey() }
                }

            Button(appState.isTfLAPIKeyConfigured ? "Save new key" : "Save API key") {
                Task { await saveKey() }
            }
            .disabled(!canSave)
        } header: {
            AppBackgroundSectionHeader(
                title: appState.isTfLAPIKeyConfigured ? "Replace key" : "API key"
            )
        } footer: {
            Text("TubeTrack UK sends app_key with API requests. An app_id is not required.")
        }
    }

    private var canSave: Bool {
        !draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.appCaption(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.tubeBlue, in: Circle())
                .accessibilityHidden(true)
            Text(text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(text)")
    }

    @MainActor
    private func saveKey() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await appState.saveTfLAPIKey(draftKey)
            draftKey = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func removeKey() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await appState.removeTfLAPIKey()
            draftKey = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

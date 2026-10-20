import SwiftUI
import UIKit

struct LiveActivityDiagnosticsScreen: View {
    @State private var reportURL: URL?
    @State private var isPreparing = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Share a troubleshooting report if scheduled journey updates stop working.")
                Text("Includes up to seven days of app and Live Activity events, device software versions, and identifiers used to match server logs. Push tokens and credentials are excluded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let reportURL {
                    ShareLink("Share diagnostics", item: reportURL)
                }
                Button(reportURL == nil ? "Prepare report" : "Refresh report") {
                    Task { await prepare() }
                }
                .disabled(isPreparing)
                if isPreparing { ProgressView("Preparing report…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Share diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await prepare() }
    }

    @MainActor private func prepare() async {
        guard !isPreparing else { return }
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }
        DepartureActivityBridge.recordDiagnosticSnapshot(reason: "export")
        let metadata = [
            "appVersion": AppInstall.appVersion,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "osVersion": UIDevice.current.systemVersion,
            "deviceFamily": UIDevice.current.model,
            "installID": AppInstall.identifier,
            "activitiesEnabled": String(DepartureActivityBridge.areActivitiesEnabled),
            "frequentUpdatesEnabled": String(DepartureActivityBridge.frequentPushesEnabled),
            "timeZone": TimeZone.current.identifier
        ]
        do {
            let url = try await LiveActivityDiagnostics.shared.export(metadata: metadata)
            try Task.checkCancellation()
            reportURL = url
        } catch is CancellationError {
        } catch {
            reportURL = nil
            errorMessage = "Could not prepare the report. Please try again."
        }
    }
}

#Preview("Diagnostics · Large text") {
    NavigationStack { LiveActivityDiagnosticsScreen() }
        .environment(\.dynamicTypeSize, .accessibility3)
        .preferredColorScheme(.dark)
}

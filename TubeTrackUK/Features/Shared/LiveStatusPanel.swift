import SwiftUI

struct LiveStatusDock: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var expanded: Bool

    private var summary: (symbol: String, color: Color, title: String, detail: String) {
        if appState.isRefreshingStatus && appState.statuses.isEmpty {
            return ("arrow.trianglehead.2.clockwise.rotate.90", .blue, "Updating Tube status", "Fetching live TfL data")
        }
        if let error = appState.statusError, appState.statuses.isEmpty {
            return ("wifi.slash", .orange, "Live status unavailable", error)
        }
        if appState.currentIssueCount > 0 {
            let count = appState.currentIssueCount
            return ("exclamationmark.triangle.fill", .red, "\(count) disruption\(count == 1 ? "" : "s")", "Tap for affected lines")
        }
        let overnight = !appState.statuses.isEmpty && appState.statuses.allSatisfy {
            $0.lineStatuses.allSatisfy(\.isOvernightClosure)
        }
        if overnight {
            return ("moon.zzz.fill", .indigo, "Tube service closed", "Service resumes later this morning")
        }
        return ("checkmark.circle.fill", .green, "Good service", "\(appState.goodServiceLineCount) of 11 lines reporting normally")
    }

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.4, bounce: 0.18)) {
                expanded.toggle()
            }
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityLayout
            } else {
                regularLayout
            }
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .zIndex(1)
        .accessibilityHint(expanded ? "Collapses live status" : "Expands live status")
    }

    private var regularLayout: some View {
        HStack(spacing: 12) {
            statusIcon
            statusText(lineLimit: 1)
            Spacer()
            FreshnessLabel(date: appState.statusUpdatedAt, cached: appState.isUsingCachedStatus)
            disclosureIcon
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
    }

    private var accessibilityLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 7) {
                statusText(lineLimit: 2)
                FreshnessLabel(date: appState.statusUpdatedAt, cached: appState.isUsingCachedStatus)
            }

            Spacer(minLength: 4)
            disclosureIcon
                .frame(width: 44, height: 44)
        }
        .padding(14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
    }

    private var statusIcon: some View {
        Image(systemName: summary.symbol)
            .font(.headline)
            .foregroundStyle(summary.color)
            .symbolEffect(.pulse, isActive: appState.isRefreshingStatus)
    }

    private func statusText(lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
            Text(summary.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
        }
    }

    private var disclosureIcon: some View {
        Image(systemName: expanded ? "chevron.down" : "chevron.up")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
    }
}

struct LiveStatusPanel: View {
    @Environment(TubeAppState.self) private var appState
    @Binding var expanded: Bool

    var body: some View {
        GlassPanel {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live Status")
                            .font(.headline)
                        FreshnessLabel(date: appState.statusUpdatedAt, cached: appState.isUsingCachedStatus)
                    }
                    Spacer()
                    Button("Close", systemImage: "xmark.circle.fill") {
                        withAnimation(.spring(duration: 0.35)) { expanded = false }
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .accessibilityHint("Collapses live status")
                }

                if appState.disruptions.isEmpty {
                    noDisruptionsView
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(appState.disruptions) { disruption in
                                DisruptionRow(disruption: disruption) {
                                    withAnimation(.spring(duration: 0.35)) { expanded = false }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: 280)
                }
            }
        }
    }

    @ViewBuilder
    private var noDisruptionsView: some View {
        let overnightStatuses = appState.statuses.flatMap { line in
            line.lineStatuses.filter(\.isOvernightClosure).map { (line.id, $0) }
        }
        if !overnightStatuses.isEmpty {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(overnightStatuses.enumerated()), id: \.offset) { _, entry in
                        let (lineID, status) = entry
                        HStack {
                            LineBadge(lineID: lineID)
                            Spacer()
                            Text(status.statusSeverityDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 230)
        } else {
            ContentUnavailableView(
                "Good service",
                systemImage: "checkmark.circle.fill",
                description: Text("No live Tube disruptions are currently reported.")
            )
            .frame(height: 160)
        }
    }
}

private struct DisruptionRow: View {
    @Environment(TubeAppState.self) private var appState
    let disruption: ResolvedDisruption
    let onSelect: () -> Void

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.55)) {
                appState.select(disruption: disruption)
                onSelect()
            }
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.tubeLine(disruption.lineID))
                    .frame(width: 5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(disruption.lineID.displayName)
                            .font(.subheadline.weight(.bold))
                        Spacer()
                        Text(disruption.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    Text(disruption.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Text(disruption.confidence.userDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(11)
            .background(.primary.opacity(0.055), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .accessibilityHint("Highlights the affected section on the map")
    }
}

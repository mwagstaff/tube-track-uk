import SwiftUI
import TubeTrackCore
import WidgetKit

/// Source time and age, with a refresh button, at the bottom of home screen widgets.
///
/// The clock time distinguishes a fresh snapshot from a remembered one, and
/// refresh asks WidgetKit to load another snapshot.
struct WidgetFooter: View {
    let freshness: Freshness
    /// The moment this entry renders — the footer ages with the timeline.
    let now: Date
    let failed: Bool
    var body: some View {
        HStack(spacing: 6) {
            if failed && freshness.updatedAt == nil {
                Label("Offline", systemImage: "wifi.slash")
                    .foregroundStyle(.red)
            } else {
                Label {
                    Text(freshness.summary(at: now))
                } icon: {
                    Image(systemName: freshness.symbolName)
                }
                .foregroundStyle(freshness.tier == .stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            Button(intent: RefreshWidgetIntent()) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Refresh")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }
}

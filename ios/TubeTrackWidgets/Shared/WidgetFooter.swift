import SwiftUI
import TubeTrackCore
import WidgetKit

/// How old the data is, in words, with an optional refresh button. Sits at the
/// bottom of medium and large widgets.
///
/// A widget cannot fetch on demand, so this is the passenger's only way to tell
/// a live board from a remembered one. It is never decorative.
struct WidgetFooter: View {
    let freshness: Freshness
    /// The moment this entry renders — the footer ages with the timeline.
    let now: Date
    let failed: Bool
    var showsRefresh = false

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
            }
            Spacer(minLength: 0)
            if showsRefresh {
                Button(intent: RefreshWidgetIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Refresh")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }
}

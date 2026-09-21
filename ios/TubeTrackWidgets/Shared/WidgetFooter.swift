import SwiftUI
import WidgetKit

/// "Updated 09:41" plus a cached/offline marker, with an optional refresh
/// button. Sits at the bottom of medium and large widgets.
struct WidgetFooter: View {
    let updatedAt: Date?
    let isCached: Bool
    let failed: Bool
    var showsRefresh = false

    var body: some View {
        HStack(spacing: 6) {
            if failed && updatedAt == nil {
                Label("Offline", systemImage: "wifi.slash")
                    .foregroundStyle(.red)
            } else if let updatedAt {
                if isCached || failed {
                    Label {
                        Text("Cached \(updatedAt, style: .time)")
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                } else {
                    Text("Updated \(updatedAt, style: .time)")
                }
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

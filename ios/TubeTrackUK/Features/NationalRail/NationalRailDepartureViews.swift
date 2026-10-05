import SwiftUI

/// The National Rail double arrow supplied in the design reference, drawn as
/// a vector so the small mark stays sharp at every Dynamic Type size.
struct NationalRailMark: View {
    @ScaledMetric(relativeTo: .caption) private var width = 20.0

    var body: some View {
        NationalRailDoubleArrow()
            .fill(.white)
            .padding(3)
            .frame(width: width, height: width * 0.72)
            .background(Color(red: 0.9, green: 0, blue: 0.08), in: .rect(cornerRadius: 2))
            .accessibilityHidden(true)
    }
}

private struct NationalRailDoubleArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let polygons: [[CGPoint]] = [
            [.init(x: 0.20, y: 0), .init(x: 0.42, y: 0), .init(x: 0.70, y: 0.24),
             .init(x: 1, y: 0.24), .init(x: 1, y: 0.40), .init(x: 0.70, y: 0.40),
             .init(x: 0.53, y: 0.60), .init(x: 1, y: 0.60), .init(x: 1, y: 0.76),
             .init(x: 0.53, y: 0.76), .init(x: 0.80, y: 1), .init(x: 0.58, y: 1),
             .init(x: 0.30, y: 0.76), .init(x: 0, y: 0.76), .init(x: 0, y: 0.60),
             .init(x: 0.30, y: 0.60), .init(x: 0.53, y: 0.40), .init(x: 0, y: 0.40),
             .init(x: 0, y: 0.24), .init(x: 0.53, y: 0.24)]
        ]
        for points in polygons {
            path.addLines(points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
            path.closeSubpath()
        }
        return path
    }
}

struct NationalRailOperatorPill: View {
    let name: String
    let id: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                NationalRailMark()
                Text(name).lineLimit(1)
                Image(systemName: "checkmark")
                    .font(.appCaption2(.bold))
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .font(.appCaption(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(uiColor: selected ? .secondarySystemFill : .tertiarySystemFill), in: .capsule)
            .overlay { Capsule().stroke(Color.primary.opacity(selected ? 0.45 : 0.08), lineWidth: 1) }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("departures-operator-\(id)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), National Rail")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint("Shows departures for this operator")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct NationalRailDepartureGroupView: View {
    @State private var expanded = false
    let group: NationalRailDepartureGroup
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                NationalRailMark()
                Text(group.name).font(.appSubheadline(.bold))
            }
            .accessibilityAddTraits(.isHeader)
            ForEach(expanded ? group.arrivals[...] : group.arrivals.prefix(3), id: \.departureIdentity) { arrival in
                StationDepartureRow(arrival: arrival, now: now)
            }
            if group.arrivals.count > 3 {
                Button { expanded.toggle() } label: {
                    Label(expanded ? "Show fewer departures" : "View all departures",
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.appCaption(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.departureAccent)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
        }
    }
}

#if DEBUG
#Preview("Rail pills — light") {
    VStack {
        NationalRailOperatorPill(name: "Southeastern", id: "SE", selected: true) {}
        NationalRailOperatorPill(name: "Southern", id: "SN", selected: false) {}
    }.padding()
}

#Preview("Rail pills — dark, large text") {
    NationalRailOperatorPill(name: "South Western Railway", id: "SW", selected: true) {}
        .padding().preferredColorScheme(.dark).environment(\.dynamicTypeSize, .accessibility3)
}
#endif

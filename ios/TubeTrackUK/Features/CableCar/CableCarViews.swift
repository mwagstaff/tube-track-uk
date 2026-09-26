import MapKit
import SwiftUI

/// A gondola rather than the street tram represented by SF Symbols' cablecar.
/// Native paths also render reliably in the retained schematic Canvas.
struct CableCarGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var cable = Path()
        cable.move(to: CGPoint(x: 2, y: 7)); cable.addLine(to: CGPoint(x: 22, y: 1))
        cable.move(to: CGPoint(x: 12, y: 4)); cable.addLine(to: CGPoint(x: 15, y: 8)); cable.addLine(to: CGPoint(x: 12, y: 11))
        var result = cable.strokedPath(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        var cabin = Path()
        cabin.move(to: CGPoint(x: 7, y: 11)); cabin.addLine(to: CGPoint(x: 17, y: 11))
        cabin.addLine(to: CGPoint(x: 20, y: 15)); cabin.addLine(to: CGPoint(x: 20, y: 20))
        cabin.addQuadCurve(to: CGPoint(x: 18, y: 22), control: CGPoint(x: 20, y: 22))
        cabin.addLine(to: CGPoint(x: 6, y: 22)); cabin.addQuadCurve(to: CGPoint(x: 4, y: 20), control: CGPoint(x: 4, y: 22))
        cabin.addLine(to: CGPoint(x: 4, y: 15)); cabin.closeSubpath()
        cabin.addRect(CGRect(x: 7, y: 13, width: 4, height: 4))
        cabin.addRect(CGRect(x: 13, y: 13, width: 4, height: 4))
        result.addPath(cabin)
        return result.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}

struct CableCarTerminalSymbol: View {
    let selected: Bool
    let tint: Color
    var expanded = true
    var compactDiameter: CGFloat = 11
    var body: some View {
        let showsIcon = expanded || selected
        ZStack {
            Circle()
                .fill(selected ? tint : Color(.systemBackground))
                .overlay { Circle().stroke(tint, lineWidth: showsIcon ? 2 : (compactDiameter < 8 ? 1.25 : 2)) }
            if showsIcon {
                CableCarGlyph().fill(style: FillStyle(eoFill: true))
                    .frame(width: selected ? 22 : 18, height: selected ? 22 : 18)
                    .foregroundStyle(selected ? Color(.systemBackground) : tint)
            }
        }
        .frame(width: showsIcon ? (selected ? 36 : 28) : compactDiameter,
               height: showsIcon ? (selected ? 36 : 28) : compactDiameter)
    }
}

struct CableCarMapBadge: View {
    let presentation: CableCarPresentation
    var body: some View {
        Label(presentation.headline, systemImage: presentation.symbol)
            .font(.appCaption(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color(.systemBackground), in: .capsule)
            .overlay { Capsule().stroke(.secondary.opacity(0.3)) }
    }
}

struct CableCarCard: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsDetails = false
    var body: some View {
        let cable = appState.cableCar
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(cable.selectedTerminal?.name ?? "London Cable Car").font(.appHeadline())
                        if cable.selectedTerminal != nil { Text("London Cable Car").font(.appCaption()).foregroundStyle(.secondary) }
                    }.fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let terminal = cable.selectedTerminal { FavouriteStopButton(stop: .terminal(terminal)) }
                    Button("Close cable car", systemImage: "xmark.circle.fill") { cable.clearSelection() }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
                Label(cable.presentation.headline, systemImage: cable.presentation.symbol).font(.appSubheadline(.semibold))
                Text(cable.presentation.detail).font(.appSubheadline()).lineLimit(typeSize.isAccessibilitySize ? 2 : 3)
                Text(cable.presentation.schedule).font(.appCaption()).foregroundStyle(.secondary)
                Button("Service details", systemImage: "info.circle") { showsDetails = true }.font(.appSubheadline())
                CardUpdateFooter(
                    updatedAt: appState.isViewingLiveStatus ? cable.statusUpdatedAt : cable.plannedUpdatedAt,
                    isOffline: appState.isOffline,
                    isStale: appState.isViewingLiveStatus ? cable.statusStale : cable.plannedStale,
                    staleAfter: appState.isViewingLiveStatus ? 120 : 1800)
            }
        }
        .sheet(isPresented: $showsDetails) { CableCarDetails() }
    }
}

struct CableCarDetails: View {
    @Environment(TubeAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let cable = appState.cableCar
        NavigationStack {
            List {
                Section(appState.isViewingLiveStatus ? "Current service" : "Selected date") {
                    Label(cable.presentation.headline, systemImage: cable.presentation.symbol)
                    Text(cable.presentation.detail)
                    Text(cable.presentation.schedule)
                    if appState.isViewingLiveStatus {
                        if let updated = cable.statusUpdatedAt {
                            Text("TfL update: \(LondonRailDate.formatted(updated, dateFormat: "d MMM HH:mm"))")
                                .foregroundStyle(.secondary)
                        }
                        if cable.statusStale || appState.isOffline || Date.now.timeIntervalSince(cable.statusUpdatedAt ?? .distantPast) > 120 {
                            Text("Live status is unconfirmed. Any previous TfL report below may be out of date.").foregroundStyle(.secondary)
                        }
                        ForEach(Array((cable.status?.entries ?? []).enumerated()), id: \.offset) { _, entry in
                            Text("TfL report: \(entry.reason ?? entry.statusSeverityDescription)")
                        }
                    }
                }
                Section("Terminals") {
                    ForEach(cable.network.terminals) { terminal in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Button(terminal.name) { dismiss(); appState.selectCableCar(terminal: terminal) }
                                Spacer()
                                FavouriteStopButton(stop: .terminal(terminal))
                            }
                            Button("Walk from \(terminal.railStationName)", systemImage: "figure.walk") {
                                let item = MKMapItem(location: CLLocation(latitude: terminal.latitude, longitude: terminal.longitude), address: nil)
                                item.name = terminal.name
                                if let id = terminal.railStationID, let station = appState.graph?.stationsByID[id] {
                                    let start = MKMapItem(location: CLLocation(latitude: station.coordinate.latitude, longitude: station.coordinate.longitude), address: nil)
                                    start.name = station.name
                                    MKMapItem.openMaps(with: [start, item], launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                                }
                            }.disabled(appState.isOffline)
                        }
                    }
                }
                Section("Planned changes") {
                    Text(appState.isViewingLiveStatus ? (cable.planned == nil ? "Planned cable car work unavailable" : cable.plannedStale || appState.isOffline ? "Saved future reports may be out of date" : "Upcoming changes reported by TfL") : cable.plannedMessage).foregroundStyle(.secondary)
                    ForEach(appState.isViewingLiveStatus ? (cable.planned?.works ?? []).filter { $0.end > .now } : cable.visibleWorks) { work in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(work.title).font(.headline)
                            Text(work.reason ?? "TfL planned service change")
                            Text(work.timeDescription).font(.caption)
                        }
                    }
                    Text("Future reports may be incomplete. No reported work is not a guarantee of service.").font(.caption)
                    Link("Check TfL status", destination: URL(string: "https://tfl.gov.uk/cable-car/status")!)
                }
                Section("Published operating information") {
                    Text("Cabins normally arrive approximately every 30 seconds. A one-way journey takes up to 10 minutes.")
                    if let hours = cable.hours {
                        if hours.isVerified == false { Text("TfL’s timetable has changed. Opening hours are awaiting review.").foregroundStyle(.secondary) }
                        Text("Hours reviewed \(hours.reviewedOn); valid through \(hours.validThrough). Times are London local time.").font(.caption).foregroundStyle(.secondary)
                        Link("TfL opening hours", destination: URL(string: hours.sourceURL) ?? URL(string: "https://tfl.gov.uk/modes/london-cable-car/")!)
                    }
                    Text("Data provided by Transport for London").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .navigationTitle("London Cable Car")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct CableCarStatusRow: View {
    @Environment(TubeAppState.self) private var appState
    var onSelect: () -> Void = {}
    var body: some View {
        Button { appState.selectCableCar(); onSelect() } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label("London Cable Car · \(appState.cableCar.presentation.headline)", image: "CableCarIcon")
                    .font(.appSubheadline(.semibold))
                Text(appState.isViewingLiveStatus ? appState.cableCar.presentation.detail : appState.cableCar.plannedMessage)
                    .font(.appCaption()).foregroundStyle(.secondary)
                if !appState.isViewingLiveStatus {
                    ForEach(appState.cableCar.visibleWorks) { work in
                        Text("\(work.title) · \(work.timeDescription)").font(.appCaption())
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
    }
}

import SwiftUI

private enum WorksPeriod: String, CaseIterable, Identifiable {
    case all = "All dates"
    case weekend = "This weekend"
    case thirtyDays = "Next 30 days"

    var id: Self { self }
}

struct WorksScreen: View {
    @Environment(TubeAppState.self) private var appState
    @State private var period: WorksPeriod = .all
    @State private var selectedLine: TubeLineID?
    @State private var selectedWork: EngineeringWork?

    private var filteredWorks: [EngineeringWork] {
        appState.engineeringWorks.filter { work in
            let matchesLine = selectedLine.map { work.lineIDs.contains($0) } ?? true
            return matchesLine && matchesPeriod(work)
        }
    }

    private var groupedWorks: [(date: Date, works: [EngineeringWork])] {
        let calendar = LondonRailDate.calendar
        let groups = Dictionary(grouping: filteredWorks) { calendar.startOfDay(for: $0.startDate) }
        return groups.keys.sorted().map { ($0, groups[$0, default: []].sorted { $0.startDate < $1.startDate }) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if appState.isRefreshingWorks && appState.engineeringWorks.isEmpty {
                    ProgressView("Loading planned works…")
                } else if filteredWorks.isEmpty {
                    emptyState
                } else {
                    worksList
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Engineering Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Date range", selection: $period) {
                            ForEach(WorksPeriod.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label("Filter works", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                lineFilter
                    .padding(.vertical, 7)
                    .background(.bar)
            }
            .refreshable { await appState.refreshWorks() }
            .sheet(item: $selectedWork) { WorkDetailView(work: $0) }
        }
    }

    private var worksList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: .sectionHeaders) {
                ForEach(groupedWorks, id: \.date) { group in
                    Section {
                        ForEach(group.works) { work in
                            Button { selectedWork = work } label: { WorkCard(work: work) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        Text(LondonRailDate.formatted(group.date, dateFormat: "EEEE d MMMM"))
                            .font(.subheadline.weight(.bold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 7)
                            .background(Color(.systemGroupedBackground))
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
    }

    private var lineFilter: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                filterButton(title: "All lines", line: nil, color: .tubeBlue)
                ForEach(TubeLineID.allCases) { line in
                    filterButton(title: line.displayName, line: line, color: .tubeLine(line))
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func filterButton(title: String, line: TubeLineID?, color: Color) -> some View {
        let selected = selectedLine == line
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedLine = line }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(selected ? Color.tubeBlue : Color.secondary.opacity(0.13), in: .capsule)
            .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(appState.worksError == nil ? "No planned works" : "Works unavailable", systemImage: appState.worksError == nil ? "checkmark.circle" : "wifi.slash")
        } description: {
            Text(appState.worksError ?? "No TfL engineering work matches these filters in the next 60 days.")
        } actions: {
            Button("Refresh") { Task { await appState.refreshWorks() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private func matchesPeriod(_ work: EngineeringWork) -> Bool {
        switch period {
        case .all:
            return true
        case .thirtyDays:
            let end = LondonRailDate.calendar.date(byAdding: .day, value: 30, to: .now) ?? .now
            return work.startDate <= end && work.endDate >= .now
        case .weekend:
            let calendar = LondonRailDate.calendar
            let today = calendar.startOfDay(for: .now)
            let weekday = calendar.component(.weekday, from: today)
            let daysToSaturday = (7 - weekday + 7) % 7
            let saturday = calendar.date(byAdding: .day, value: daysToSaturday, to: today) ?? today
            let monday = calendar.date(byAdding: .day, value: 2, to: saturday) ?? saturday
            return work.startDate < monday && work.endDate > saturday
        }
    }
}

private struct WorkCard: View {
    let work: EngineeringWork

    var body: some View {
        HStack(spacing: 13) {
            VStack(spacing: 3) {
                ForEach(work.lineIDs) { line in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.tubeLine(line))
                        .frame(width: 6)
                }
            }
            .frame(width: 6)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 5) {
                            ForEach(work.lineIDs) { LineBadge(lineID: $0) }
                        }
                    }
                    .scrollIndicators(.hidden)
                    Spacer(minLength: 4)
                    Text(work.confidence == .lineOnly ? "Line-wide" : "Section")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                }
                Text(work.title).font(.headline)
                Text(work.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                Label(dateRange, systemImage: "calendar")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(15)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    private var dateRange: String {
        if LondonRailDate.calendar.isDate(work.startDate, inSameDayAs: work.endDate) {
            return LondonRailDate.formatted(
                work.startDate,
                dateFormat: "EEE d MMM, HH:mm"
            )
        }
        let start = LondonRailDate.formatted(work.startDate, dateFormat: "d MMM")
        let end = LondonRailDate.formatted(work.endDate, dateFormat: "d MMM")
        return "\(start) – \(end)"
    }
}

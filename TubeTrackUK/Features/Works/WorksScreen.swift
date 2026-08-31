import SwiftUI

enum WorksDateSelection: Equatable, Sendable {
    case today
    case tomorrow
    case saturday
    case sunday
    case custom(Date)

    func date(
        relativeTo referenceDate: Date = .now,
        calendar: Calendar = LondonRailDate.calendar
    ) -> Date {
        let today = calendar.startOfDay(for: referenceDate)
        switch self {
        case .today:
            return today
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: today) ?? today
        case .saturday:
            return next(
                weekday: 7,
                from: referenceDate,
                calendar: calendar
            )
        case .sunday:
            return next(
                weekday: 1,
                from: referenceDate,
                calendar: calendar
            )
        case let .custom(date):
            return calendar.startOfDay(for: date)
        }
    }

    private func next(
        weekday: Int,
        from referenceDate: Date,
        calendar: Calendar
    ) -> Date {
        let today = calendar.startOfDay(for: referenceDate)
        let currentWeekday = calendar.component(.weekday, from: today)
        let inclusiveOffset = (weekday - currentWeekday + 7) % 7
        let dayOffset = inclusiveOffset == 0 ? 7 : inclusiveOffset
        return calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
    }
}

private struct WorksQuickDate: Identifiable {
    let title: String
    let selection: WorksDateSelection

    var id: String { title }
}

struct WorksScreen: View {
    @Environment(TubeAppState.self) private var appState
    @State private var dateSelection: WorksDateSelection = .today
    @State private var selectedLine: TubeLineID?
    @State private var selectedWork: EngineeringWork?
    @State private var showsDatePicker = false
    @State private var draftDate = Date.now

    private var selectedDate: Date {
        dateSelection.date()
    }

    private var quickDates: [WorksQuickDate] {
        [
            WorksQuickDate(title: "Today", selection: .today),
            WorksQuickDate(title: "Tomorrow", selection: .tomorrow),
            WorksQuickDate(title: "Saturday", selection: .saturday),
            WorksQuickDate(title: "Sunday", selection: .sunday),
        ]
    }

    private var filteredWorks: [EngineeringWork] {
        LondonRailDate.works(
            appState.engineeringWorks,
            overlapping: selectedDate
        )
        .filter { work in
            selectedLine.map { work.lineIDs.contains($0) } ?? true
        }
        .sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
        NavigationStack {
            Group {
                if appState.isRefreshingWorks && filteredWorks.isEmpty {
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
                    Button {
                        draftDate = selectedDate
                        showsDatePicker = true
                    } label: {
                        Label("Choose date", systemImage: "calendar")
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    lineFilter
                    quickDateFilter
                }
                .padding(.vertical, 7)
                .background(.bar)
            }
            .refreshable {
                await appState.refreshWorks(
                    through: selectedDate,
                    forceRefresh: true
                )
            }
            .sheet(item: $selectedWork) { WorkDetailView(work: $0) }
            .sheet(isPresented: $showsDatePicker) {
                customDatePicker
            }
            .task(id: selectedDate) {
                await appState.refreshWorks(through: selectedDate)
            }
            .onAppear {
                resetPastSelectionIfNeeded()
            }
        }
    }

    private var worksList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: .sectionHeaders) {
                Section {
                    ForEach(filteredWorks) { work in
                        Button { selectedWork = work } label: { WorkCard(work: work) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    Text(LondonRailDate.formatted(selectedDate, dateFormat: "EEEE d MMMM"))
                        .font(.subheadline.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                        .background(Color(.systemGroupedBackground))
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
    }

    private var quickDateFilter: some View {
        HStack(spacing: 8) {
            ForEach(quickDates) { quickDate in
                quickDateButton(quickDate)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 8)
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

    private func quickDateButton(_ quickDate: WorksQuickDate) -> some View {
        let selected = dateSelection == quickDate.selection
        let date = quickDate.selection.date()

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                dateSelection = quickDate.selection
            }
        } label: {
            VStack(spacing: 1) {
                Text(quickDate.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(LondonRailDate.formatted(date, dateFormat: "d MMM"))
                    .font(.caption2)
                    .opacity(selected ? 0.85 : 0.65)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                Capsule(style: .continuous)
                    .fill(selected ? Color.tubeBlue : Color.secondary.opacity(0.13))
            }
            .clipShape(Capsule(style: .continuous))
            .contentShape(.capsule)
            .foregroundStyle(selected ? .white : .primary)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(quickDate.title), \(LondonRailDate.formatted(date, dateFormat: "EEEE d MMMM yyyy"))"
        )
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                appState.worksError == nil ? "No planned works" : "Works unavailable",
                systemImage: appState.worksError == nil ? "checkmark.circle" : "wifi.slash"
            )
        } description: {
            Text(appState.worksError ?? emptyStateDescription)
        } actions: {
            Button("Refresh") {
                Task {
                    await appState.refreshWorks(
                        through: selectedDate,
                        forceRefresh: true
                    )
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyStateDescription: String {
        let date = LondonRailDate.formatted(selectedDate, dateFormat: "EEEE d MMMM")
        if let selectedLine {
            return "No TfL engineering work is reported for the \(selectedLine.displayName) line on \(date)."
        }
        return "No TfL engineering work is reported for \(date)."
    }

    private var customDatePicker: some View {
        NavigationStack {
            DatePicker(
                "Works date",
                selection: $draftDate,
                in: LondonRailDate.startOfDay(for: .now)...Date.distantFuture,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding()
            .navigationTitle("Choose a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showsDatePicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dateSelection = .custom(draftDate)
                        showsDatePicker = false
                    }
                }
            }
        }
        .environment(\.calendar, LondonRailDate.calendar)
        .environment(\.timeZone, LondonRailDate.timeZone)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func resetPastSelectionIfNeeded() {
        let today = LondonRailDate.startOfDay(for: .now)
        guard selectedDate < today else { return }
        dateSelection = .today
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

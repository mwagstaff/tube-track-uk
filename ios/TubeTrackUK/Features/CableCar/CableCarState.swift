import Foundation
import Observation

struct CableCarSnapshot<Value: Codable & Sendable>: Codable, Sendable {
    let data: Value
    let updatedAt: Date
}

@MainActor @Observable
final class CableCarState {
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: "cableCarEnabled"); if !isEnabled { clearSelection() } }
    }
    private(set) var network: CableCarNetwork
    private(set) var hours: CableCarHours?
    private(set) var status: CableCarStatus?
    private(set) var statusUpdatedAt: Date?
    private(set) var statusStale = true
    private(set) var planned: CableCarWorks?
    private(set) var plannedUpdatedAt: Date?
    private(set) var plannedStale = true
    private(set) var selectedTerminalID: String?
    private(set) var hasSelection = false
    private(set) var selectionGeneration = 0
    private(set) var presentation = CableCarPolicy.resolve(now: .now, status: nil, updatedAt: nil, stale: true, hours: nil, works: [])
    private(set) var visibleWorks: [CableCarWork] = []
    private(set) var plannedMessage = "Planned cable car work unavailable"
    private(set) var isLoading = false
    @ObservationIgnored private let client: TubeTrackAPIClient
    @ObservationIgnored private let cache: SnapshotCache
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var restoration: Task<Void, Never>?
    @ObservationIgnored private var metadataUpdatedAt: Date?
    @ObservationIgnored private var plannedDate: Date?
    @ObservationIgnored private var windows: Set<DisruptionTimeWindow> = .init(DisruptionTimeWindow.defaultSelected)
    @ObservationIgnored private var offline = false

    init(client: TubeTrackAPIClient, defaults: UserDefaults = .standard, cache: SnapshotCache = SnapshotCache()) {
        self.client = client; self.defaults = defaults; self.cache = cache
        isEnabled = defaults.object(forKey: "cableCarEnabled") as? Bool ?? true
        network = RiverBundle.load("CableCarNetwork", as: CableCarNetwork.self) ?? .empty
        hours = RiverBundle.load("CableCarHours", as: CableCarHours.self)
        updatePresentation()
    }
    var selectedTerminal: CableCarTerminal? { network.terminals.first { $0.id == selectedTerminalID } }
    var issueCount: Int { isEnabled && plannedDate == nil && presentation.isIssue ? 1 : 0 }
    var overviewIssueCount: Int {
        guard isEnabled else { return 0 }
        guard plannedDate != nil else { return issueCount }
        return !isOverviewUnconfirmed && !visibleWorks.isEmpty ? 1 : 0
    }
    var isOverviewUnconfirmed: Bool {
        guard isEnabled else { return false }
        guard let plannedDate else { return presentation.kind == .unknown }
        return plannedStale || offline || planned?.covers(plannedDate) != true
            || plannedUpdatedAt.map { Date.now.timeIntervalSince($0) > 1800 } != false
    }
    func clearSelection() { selectedTerminalID = nil; hasSelection = false }
    func select(_ terminal: CableCarTerminal? = nil) {
        isEnabled = true; hasSelection = true; selectedTerminalID = terminal?.id; selectionGeneration &+= 1
    }

    func restore() async {
        if let restoration { await restoration.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.restoreCache()
        }
        restoration = task
        await task.value
    }

    private func restoreCache() async {
        if let saved = try? await cache.load(CableCarNetwork.self, named: "cable-car-network.json"), saved.terminals.count == 2 { network = saved }
        if let saved = try? await cache.load(CableCarHours.self, named: "cable-car-hours.json"),
           saved.reviewedOn >= (hours?.reviewedOn ?? "") { hours = saved }
        if let saved = try? await cache.load(CableCarSnapshot<CableCarStatus>.self, named: "cable-car-status.json") {
            status = saved.data; statusUpdatedAt = saved.updatedAt
        }
        if let saved = try? await cache.load(CableCarSnapshot<CableCarWorks>.self, named: "cable-car-works.json") {
            planned = saved.data; plannedUpdatedAt = saved.updatedAt
        }
        updatePresentation()
    }

    func setContext(date: Date?, windows: Set<DisruptionTimeWindow>, offline: Bool) {
        plannedDate = date; self.windows = windows; self.offline = offline; updatePresentation()
    }

    func updatePresentation(now: Date = .now) {
        let planFresh = !plannedStale && !offline && plannedUpdatedAt.map { now.timeIntervalSince($0) <= 1800 } == true
        let target = plannedDate ?? now
        let selectedIntervals = windows.map { $0.interval(on: target) }
        let matches = (planned?.works ?? []).filter { work in selectedIntervals.contains { work.overlaps($0) } }
        if visibleWorks != matches { visibleWorks = matches }
        let message: String
        if windows.isEmpty { message = "Choose AM, PM or Overnight" }
        else if planned?.covers(target) != true { message = "Planned cable car work unavailable for this date" }
        else if !planFresh { message = "Saved cable car work may be out of date" }
        else if planned?.undatedCount ?? 0 > 0 { message = "TfL also reports changes without confirmed dates" }
        else { message = matches.isEmpty ? "No cable car work reported for these times" : "TfL reported cable car work" }
        if plannedMessage != message { plannedMessage = message }
        let next: CableCarPresentation
        if plannedDate != nil {
            let closures = matches.filter(\.closesService)
            // Only claim a full closure when the union covers EVERY selected window.
            let fullClosure = CableCarPolicy.covers(selectedIntervals, with: closures)
            let confirmed = planFresh && planned?.covers(target) == true
            let schedule = hours?.intervals(on: target, now: now)
            let outsideHours = schedule.map { openings in
                !selectedIntervals.isEmpty && selectedIntervals.allSatisfy { window in
                    !openings.contains { $0.start < window.end && $0.end > window.start }
                }
            } ?? false
            let scheduleText = schedule.map { openings in
                openings.isEmpty ? "No scheduled service" : "Published hours " + openings.map {
                    "\(LondonRailDate.formatted($0.start, dateFormat: "HH:mm"))–\(LondonRailDate.formatted($0.end, dateFormat: "HH:mm"))"
                }.joined(separator: ", ")
            } ?? "Opening hours unavailable"
            let kind: CableCarPresentation.Kind = confirmed && fullClosure ? .plannedClosed : outsideHours ? .scheduledClosed : .planned
            let headline = confirmed && fullClosure ? "Closed · planned work" : outsideHours ? "Closed · outside hours"
                : !closures.isEmpty ? (confirmed ? "Closure in selected times" : "Saved closure · unconfirmed") : "Planned status"
            next = .init(kind: kind, headline: headline, detail: message,
                schedule: "\(LondonRailDate.formatted(target, dateFormat: "EEE d MMM")) · \(scheduleText)")
        } else {
            next = CableCarPolicy.resolve(now: now, status: status, updatedAt: statusUpdatedAt,
                stale: statusStale || offline, hours: hours, works: planFresh ? planned?.works ?? [] : [])
        }
        if presentation != next { presentation = next }
    }

    func poll() async {
        await restore()
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
    func refresh() async {
        guard isEnabled, !offline, !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false; updatePresentation() }
        async let metadata: Void = refreshMetadata()
        async let live: Void = refreshStatus()
        async let works: Void = refreshWorks()
        _ = await (metadata, live, works)
    }
    private func refreshMetadata() async {
        guard metadataUpdatedAt == nil || Date.now.timeIntervalSince(metadataUpdatedAt!) >= 21_600 else { return }
        do {
            let response: TubeTrackAPIResponse<CableCarNetwork> = try await client.getSnapshot("/api/v1/cable-car/network")
            try Task.checkCancellation()
            if response.data.terminals.count == 2 { network = response.data; try? await cache.save(network, named: "cable-car-network.json") }
        } catch { if Task.isCancelled { return } }
        do {
            let response: TubeTrackAPIResponse<CableCarHours> = try await client.getSnapshot("/api/v1/cable-car/hours")
            try Task.checkCancellation()
            hours = response.data; metadataUpdatedAt = response.updatedAt
            try? await cache.save(response.data, named: "cable-car-hours.json")
        } catch { /* The reviewed bundle remains usable only until its own expiry. */ }
    }
    private func refreshStatus() async {
        do {
            let response: TubeTrackAPIResponse<CableCarStatus> = try await client.getSnapshot("/api/v1/cable-car/status")
            try Task.checkCancellation()
            status = response.data; statusUpdatedAt = response.updatedAt; statusStale = response.stale
            try? await cache.save(CableCarSnapshot(data: response.data, updatedAt: response.updatedAt), named: "cable-car-status.json")
        } catch { if !Task.isCancelled { statusStale = true } }
    }
    private func refreshWorks() async {
        let date = plannedDate ?? .now
        guard planned?.covers(date) != true || plannedUpdatedAt == nil || Date.now.timeIntervalSince(plannedUpdatedAt!) >= 600 || plannedStale else { return }
        let start = min(LondonRailDate.startOfDay(for: .now), LondonRailDate.startOfDay(for: date))
        let end = LondonRailDate.calendar.date(byAdding: .day, value: 62, to: start) ?? date
        do {
            let response: TubeTrackAPIResponse<CableCarWorks> = try await client.getSnapshot("/api/v1/cable-car/planned-works", queryItems: [
                .init(name: "from", value: CableCarHours.dayKey(start)), .init(name: "to", value: CableCarHours.dayKey(end))])
            try Task.checkCancellation()
            planned = response.data; plannedUpdatedAt = response.updatedAt; plannedStale = response.stale
            try? await cache.save(CableCarSnapshot(data: response.data, updatedAt: response.updatedAt), named: "cable-car-works.json")
        } catch { if !Task.isCancelled { plannedStale = true } }
    }
}

import Foundation

public struct LineStatusSummary: Identifiable, Sendable {
    public let lineID: TubeLineID
    public let condition: LineServiceCondition
    public let reason: String?

    public var id: TubeLineID { lineID }

    public init(lineID: TubeLineID, condition: LineServiceCondition, reason: String?) {
        self.lineID = lineID
        self.condition = condition
        self.reason = reason
    }
}

public enum LineStatusProjection {
    public static func rows(
        from statuses: [TfLLineStatus],
        lineIDs: [TubeLineID]
    ) -> [LineStatusSummary] {
        let byID = Dictionary(statuses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return lineIDs.map { lineID in
            let status = byID[lineID]
            let reason = status?.lineStatuses
                .first(where: { $0.isActionableIssue || $0.isOvernightClosure })?
                .reason
                .map(trimmedReason)
            return LineStatusSummary(
                lineID: lineID,
                condition: LineServiceCondition.condition(for: status),
                reason: reason
            )
        }
    }

    public static func trimmedReason(_ reason: String) -> String {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = text.firstIndex(of: ":") {
            let prefix = text[..<colon]
            if prefix.count <= 40, prefix.localizedCaseInsensitiveContains("line") {
                text = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }
}

import Foundation

/// Decodes the elements of a JSON array that this build understands and skips
/// the rest, so a line added on the server after this build shipped removes
/// one row instead of failing the whole response.
public struct LossyList<Element: Decodable & Sendable>: Decodable, Sendable {
    public let elements: [Element]
    public let skippedCount: Int

    public init(_ elements: [Element], skippedCount: Int = 0) {
        self.elements = elements
        self.skippedCount = skippedCount
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var skipped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // A failed element decode does not advance the container.
                _ = try container.decode(SkippedElement.self)
                skipped += 1
            }
        }
        self.elements = elements
        skippedCount = skipped
    }

    private struct SkippedElement: Decodable {}
}

extension LossyList: Equatable where Element: Equatable {}

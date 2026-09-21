import SwiftUI

public struct TubeLineDot: View {
    public let lineID: TubeLineID
    public var size: CGFloat = 10

    public init(
        lineID: TubeLineID,
        size: CGFloat = 10
    ) {
        self.lineID = lineID
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(Color.tubeLine(lineID))
            .frame(width: size, height: size)
            .overlay {
                if lineID == .northern || lineID == .jubilee {
                    Circle().stroke(.white.opacity(0.75), lineWidth: 1)
                }
            }
            .accessibilityHidden(true)
    }
}

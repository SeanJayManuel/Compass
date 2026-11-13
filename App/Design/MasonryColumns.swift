import SwiftUI

/// Cards in equal columns, as many as fit at `minimum` wide, each card going
/// under the shortest column so far. Unlike a grid of rows, a short card
/// never leaves a gap beside a tall one. One column below two minimums.
struct MasonryColumns: Layout {
    var minimum: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimum
        let placement = place(width: width, subviews: subviews)
        return CGSize(width: width, height: placement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = place(width: bounds.width, subviews: subviews)
        for (index, origin) in placement.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), anchor: .topLeading,
                proposal: ProposedViewSize(width: placement.columnWidth, height: nil))
        }
    }

    private func place(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], columnWidth: CGFloat, height: CGFloat) {
        let columns = max(1, Int((width + spacing) / (minimum + spacing)))
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var heights = Array(repeating: CGFloat(0), count: columns)
        var origins: [CGPoint] = []
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            // The shortest column, leftmost on a tie, so cards read in order.
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let y = heights[column] == 0 ? 0 : heights[column] + spacing
            origins.append(CGPoint(x: CGFloat(column) * (columnWidth + spacing), y: y))
            heights[column] = y + height
        }
        return (origins, columnWidth, heights.max() ?? 0)
    }
}

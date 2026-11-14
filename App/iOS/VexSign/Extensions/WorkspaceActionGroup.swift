import SwiftUI

/// Equal-width actions become a vertical group before any label needs truncating.
/// Keep the sizing decision pure so narrow widths and accessibility modes are testable.
enum WorkspaceActionSizing {
    static func shouldStack(idealWidths: [CGFloat], availableWidth: CGFloat, spacing: CGFloat, accessibility: Bool) -> Bool {
        guard !idealWidths.isEmpty else { return false }
        if accessibility { return true }
        let required = (idealWidths.max() ?? 0) * CGFloat(idealWidths.count)
            + spacing * CGFloat(max(0, idealWidths.count - 1))
        return required > max(0, availableWidth)
    }
}

struct WorkspaceActionGroup<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.layoutDirection) private var direction
    @ViewBuilder var content: Content

    var body: some View {
        WorkspaceActionLayout(forceStack: textSize.isAccessibilitySize, rightToLeft: direction == .rightToLeft) {
            content
        }
    }
}

private struct WorkspaceActionLayout: Layout {
    var forceStack: Bool
    var rightToLeft: Bool
    private let spacing = Theme.Spacing.medium

    private struct Measurement {
        let stacked: Bool
        let cellWidth: CGFloat
        let sizes: [CGSize]
        let size: CGSize
    }

    private func measure(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Measurement {
        guard !subviews.isEmpty else {
            return Measurement(stacked: false, cellWidth: 0, sizes: [], size: .zero)
        }
        let idealWidths = subviews.map { view in
            let width = view.sizeThatFits(.unspecified).width
            return width.isFinite ? max(44, width) : 44
        }
        let idealWidth = (idealWidths.max() ?? 44) * CGFloat(subviews.count)
            + spacing * CGFloat(subviews.count - 1)
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? idealWidth
        let stacked = WorkspaceActionSizing.shouldStack(
            idealWidths: idealWidths, availableWidth: width, spacing: spacing, accessibility: forceStack
        )
        let cellWidth = stacked ? width : max(0, (width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count))
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)) }
        let height = stacked
            ? sizes.reduce(0) { $0 + $1.height } + spacing * CGFloat(subviews.count - 1)
            : sizes.map(\.height).max() ?? 0
        return Measurement(stacked: stacked, cellWidth: cellWidth, sizes: sizes, size: CGSize(width: width, height: height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measure(proposal, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = measure(ProposedViewSize(width: bounds.width, height: nil), subviews)
        var offset: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = measured.sizes[index]
            let x = measured.stacked ? bounds.minX
                : (rightToLeft ? bounds.maxX - offset - measured.cellWidth : bounds.minX + offset)
            let y = measured.stacked ? bounds.minY + offset : bounds.minY + (measured.size.height - size.height) / 2
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                       proposal: ProposedViewSize(width: measured.cellWidth, height: size.height))
            offset += (measured.stacked ? size.height : measured.cellWidth) + spacing
        }
    }
}

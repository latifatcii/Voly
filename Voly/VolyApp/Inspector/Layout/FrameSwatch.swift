import SwiftUI
import VolyModels

/// Small visual of a child rect inside a parent rect, used for Frame and
/// Bounds rows in the Layout tab.
struct FrameSwatch: View {
    let child: CGRect
    let parent: CGRect
    let cellSize: CGFloat

    private var cell: CGRect {
        CGRect(x: 0, y: 0, width: cellSize, height: cellSize)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(VolyTheme.field)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(VolyTheme.hairline, lineWidth: 1))
                .frame(width: cellSize, height: cellSize)
            let rect = FrameSwatchGeometry.swatchRect(
                child: child, parent: parent, cell: cell
            )
            if rect.width > 0, rect.height > 0 {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(VolyTheme.selection.opacity(0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: 1.5)
                            .strokeBorder(VolyTheme.selection, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
    }
}

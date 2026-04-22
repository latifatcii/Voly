import CoreGraphics

/// Pure geometry for the frame/bounds swatch in the inspector Layout tab.
/// Maps a child rect inside a parent rect onto a fixed display cell,
/// preserving the child's normalized position + size. Clamps NaN/empty/
/// overflowing inputs to stay inside the cell.
public enum FrameSwatchGeometry {
    public static func swatchRect(
        child: CGRect,
        parent: CGRect,
        cell: CGRect
    ) -> CGRect {
        guard parent.width.isFinite, parent.height.isFinite,
              parent.width > 0, parent.height > 0,
              child.width.isFinite, child.height.isFinite
        else { return .zero }

        // Normalize child to 0..1 within parent, allow negative for clamp below.
        let nx = (child.minX - parent.minX) / parent.width
        let ny = (child.minY - parent.minY) / parent.height
        let nw = child.width / parent.width
        let nh = child.height / parent.height

        let px = cell.minX + nx * cell.width
        let py = cell.minY + ny * cell.height
        let pw = nw * cell.width
        let ph = nh * cell.height

        // Clamp into the cell.
        let x = max(cell.minX, min(px, cell.maxX))
        let y = max(cell.minY, min(py, cell.maxY))
        let maxX = max(x, min(px + pw, cell.maxX))
        let maxY = max(y, min(py + ph, cell.maxY))
        return CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }
}

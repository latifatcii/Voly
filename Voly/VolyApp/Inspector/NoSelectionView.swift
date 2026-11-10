import SwiftUI

struct NoSelectionView: View {
    var body: some View {
        VolyEmptyState(
            symbol: "cursorarrow.rays",
            title: "No view selected",
            message: "Click a view in a simulator, or choose one in the view tree."
        )
    }
}

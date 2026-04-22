import SwiftUI

struct NoSelectionView: View {
    var body: some View {
        ContentUnavailableView(
            "Select a view",
            systemImage: "cursorarrow.motionlines",
            description: Text("Pick a view in the hierarchy to inspect it.")
        )
    }
}

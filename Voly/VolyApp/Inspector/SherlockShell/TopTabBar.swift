import SwiftUI

/// The inspector's tabs as a row of icons. Names live in tooltips, which
/// keeps six tabs comfortable at the panel's narrowest width.
struct TopTabBar: View {
    @Bindable var pane: InspectorPane
    let hasSelection: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(DetailTab.allCases) { tab in
                let enabled = !tab.requiresSelection || hasSelection
                Button {
                    pane.currentTab = tab
                } label: {
                    Label(tab.title, systemImage: tab.symbol)
                }
                .buttonStyle(VolyIconButtonStyle(isOn: pane.currentTab == tab))
                .disabled(!enabled)
                .help(enabled ? tab.title : "\(tab.title) — select a view first")
                .accessibilityAddTraits(pane.currentTab == tab ? .isSelected : [])
            }
        }
    }
}

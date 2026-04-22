import SwiftUI

struct TopTabBar: View {
    @Bindable var pane: InspectorPane
    let hasSelection: Bool

    var body: some View {
        Picker(selection: $pane.currentTab) {
            ForEach(DetailTab.allCases) { tab in
                Label {
                    Text(tab.label)
                        .font(.system(size: 11, weight: .medium))
                } icon: {
                    Image(systemName: tab.symbol)
                }
                .labelStyle(TabLabelStyle())
                .disabled(tab.requiresSelection && !hasSelection)
                .tag(tab)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

private struct TabLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Settings → Tabs: show, hide and reorder the dock tabs. On iPad the dock's own Edit button
/// (top bar or sidebar) edits the same stored layout.
struct SettingsTabsView: View {
    @AppStorage(AppTab.customizationStorageKey) private var tabCustomization = AppTab.defaultCustomization()
    @AppStorage(AppTab.orderStorageKey) private var tabOrderRaw = AppTab.defaultOrderRaw
    @Environment(\.editMode) private var editMode

    private var isEditing: Bool { editMode?.wrappedValue.isEditing == true }

    var body: some View {
        List {
            Section {
                ForEach(AppTab.ordered(from: tabOrderRaw).filter { $0 != .library || UIDevice.current.userInterfaceIdiom != .pad }, id: \.self) { tab in
                    if isEditing {
                        Label(tab.label, systemImage: tab.systemImage)
                    } else {
                        Toggle(isOn: visibilityBinding(for: tab)) {
                            Label(tab.label, systemImage: tab.systemImage)
                        }
                        .disabled(!tab.canHide)
                    }
                }
                .onMove(perform: moveTabs)
            } header: {
                Text("Tabs")
            } footer: {
                Text("Turn off a tab to hide it from the tab bar. Tap Edit to drag rows into a new order. On iPad, you can also tap Edit at the top of the sidebar. Home and Search always stay.")
            }

            Section {
                Button("Reset Tabs") {
                    tabOrderRaw = AppTab.defaultOrderRaw
                    tabCustomization = AppTab.defaultCustomization()
                }
            }
        }
        .navigationTitle("Tabs")
        .musicNavigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(MusicDesign.settingsBackground)
        .toolbar {
            ToolbarItem(placement: MusicToolbar.trailingItemPlacement) {
                EditButton()
            }
        }
    }

    private func visibilityBinding(for tab: AppTab) -> Binding<Bool> {
        Binding(
            get: { tabCustomization[sidebarVisibility: tab.customizationID] != .hidden },
            set: { isOn in
                tabCustomization[sidebarVisibility: tab.customizationID] = isOn ? .automatic : .hidden
            }
        )
    }

    private func moveTabs(from offsets: IndexSet, to destination: Int) {
        var order = AppTab.ordered(from: tabOrderRaw)
        order.move(fromOffsets: offsets, toOffset: destination)
        tabOrderRaw = AppTab.raw(from: order)
        tabCustomization.resetSectionOrder()
    }
}

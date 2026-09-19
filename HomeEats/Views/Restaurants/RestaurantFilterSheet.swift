import SwiftUI

/// The restaurant-list filter pop-up — "show all," select metro area(s),
/// select/unselect cuisine(s). Both facets are independent multi-selects
/// (a metro-area pick and a cuisine pick narrow the list together, and
/// several of either can be selected at once); "Show All" is just a reset
/// of both back to "no filter." Direct user request: "let's add a filter
/// button where you can 'show all', select metro areas or select/unselect
/// cuisines."
struct RestaurantFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedMetroAreas: Set<String>
    @Binding var selectedCuisines: Set<String>
    let availableMetroAreas: [String]
    let availableCuisines: [String]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Show All") {
                        selectedMetroAreas = []
                        selectedCuisines = []
                    }
                    .disabled(selectedMetroAreas.isEmpty && selectedCuisines.isEmpty)
                }
                if !availableMetroAreas.isEmpty {
                    Section("Metro Area") {
                        ForEach(availableMetroAreas, id: \.self) { area in
                            toggleRow(area, isSelected: selectedMetroAreas.contains(area)) {
                                if selectedMetroAreas.contains(area) {
                                    selectedMetroAreas.remove(area)
                                } else {
                                    selectedMetroAreas.insert(area)
                                }
                            }
                        }
                    }
                }
                if !availableCuisines.isEmpty {
                    Section("Cuisine") {
                        ForEach(availableCuisines, id: \.self) { cuisine in
                            toggleRow(cuisine, isSelected: selectedCuisines.contains(cuisine)) {
                                if selectedCuisines.contains(cuisine) {
                                    selectedCuisines.remove(cuisine)
                                } else {
                                    selectedCuisines.insert(cuisine)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Filter Restaurants")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func toggleRow(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}

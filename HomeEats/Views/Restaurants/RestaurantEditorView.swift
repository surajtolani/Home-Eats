import SwiftUI
import SwiftData

/// Add or edit a restaurant. Restaurants are lightweight compared to
/// recipes — just enough to assign an eating-out night to a day and let
/// everyone see where.
struct RestaurantEditorView: View {
    var existing: Restaurant?
    var onSave: (Restaurant) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name: String = ""
    @State private var cuisine: String = ""
    @State private var notes: String = ""
    @State private var websiteURL: String = ""
    @State private var isFavorite: Bool = false

    init(existing: Restaurant? = nil, onSave: @escaping (Restaurant) -> Void = { _ in }) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _cuisine = State(initialValue: existing?.cuisine ?? "")
        _notes = State(initialValue: existing?.notes ?? "")
        _websiteURL = State(initialValue: existing?.websiteURL ?? "")
        _isFavorite = State(initialValue: existing?.isFavorite ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Restaurant") {
                    TextField("Name", text: $name)
                    TextField("Cuisine (optional)", text: $cuisine)
                    TextField("Website (optional)", text: $websiteURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Toggle("Favorite", isOn: $isFavorite)
                }
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }
            }
            .navigationTitle(existing == nil ? "New Restaurant" : "Edit Restaurant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let restaurant = existing ?? Restaurant(name: name)
        restaurant.name = name.trimmingCharacters(in: .whitespaces)
        restaurant.cuisine = cuisine.isEmpty ? nil : cuisine
        restaurant.notes = notes.isEmpty ? nil : notes
        restaurant.websiteURL = websiteURL.isEmpty ? nil : websiteURL
        restaurant.isFavorite = isFavorite
        if existing == nil {
            modelContext.insert(restaurant)
        }
        onSave(restaurant)
        dismiss()
    }
}

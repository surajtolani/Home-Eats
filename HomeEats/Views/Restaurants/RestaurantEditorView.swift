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
    @State private var priceRange: String?
    @State private var rating: Int?
    @State private var notes: String = ""
    @State private var websiteURL: String = ""
    @State private var address: String = ""
    @State private var isFavorite: Bool = false

    private static let priceOptions = ["$", "$$", "$$$", "$$$$"]

    init(existing: Restaurant? = nil, onSave: @escaping (Restaurant) -> Void = { _ in }) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _cuisine = State(initialValue: existing?.cuisine ?? "")
        _priceRange = State(initialValue: existing?.priceRange)
        _rating = State(initialValue: existing?.rating)
        _notes = State(initialValue: existing?.notes ?? "")
        _websiteURL = State(initialValue: existing?.websiteURL ?? "")
        _address = State(initialValue: existing?.address ?? "")
        _isFavorite = State(initialValue: existing?.isFavorite ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Cuisine (optional)", text: $cuisine)
                    TextField("Address (optional)", text: $address)
                        .textInputAutocapitalization(.words)
                    TextField("Website (optional)", text: $websiteURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Toggle("Favorite", isOn: $isFavorite)
                } header: {
                    Text("Restaurant")
                } footer: {
                    Text("Adding an address shows a map and lets you open the spot directly in Google Maps for reviews and photos.")
                        .font(.brandSubheadline)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Picker("Price", selection: $priceRange) {
                        Text("Not set").tag(String?.none)
                        ForEach(Self.priceOptions, id: \.self) { option in
                            Text(option).tag(String?.some(option))
                        }
                    }
                    .pickerStyle(.segmented)
                    StarRatingPicker(rating: $rating)
                } header: {
                    Text("Your Rating & Price")
                } footer: {
                    Text("These are your household's own notes, not pulled from Google — Apple's free place search (what the search bar above uses) doesn't expose ratings or price level.")
                        .font(.brandSubheadline)
                        .foregroundStyle(.secondary)
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
        restaurant.priceRange = priceRange
        restaurant.rating = rating
        restaurant.notes = notes.isEmpty ? nil : notes
        restaurant.websiteURL = websiteURL.isEmpty ? nil : websiteURL
        restaurant.address = address.isEmpty ? nil : address
        restaurant.isFavorite = isFavorite
        if existing == nil {
            modelContext.insert(restaurant)
        }
        onSave(restaurant)
        dismiss()
    }
}

/// A row of 5 tappable stars. Tapping the currently-set star clears the
/// rating instead of re-setting it to the same value, so there's a way back
/// to "no rating" without a separate control.
private struct StarRatingPicker: View {
    @Binding var rating: Int?

    var body: some View {
        HStack {
            Text("Rating")
            Spacer()
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= (rating ?? 0) ? "star.fill" : "star")
                    .foregroundStyle(star <= (rating ?? 0) ? Color.brandHoney : Color.secondary)
                    .onTapGesture {
                        rating = (rating == star) ? nil : star
                    }
            }
        }
    }
}

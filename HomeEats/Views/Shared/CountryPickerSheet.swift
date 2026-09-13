import SwiftUI

/// A searchable list of `CountryCode.all`, presented as a sheet from a
/// dial-code button. Originally lived as a `private struct` inside
/// `AccountSignInView.swift` (its only caller at the time); factored out
/// into its own file here so `ContactOrPhoneNumberPickerView`'s manual
/// phone-entry path can present the exact same picker instead of growing a
/// second, differently-behaved one — a phone number typed while adding a
/// group member should look and work identically to one typed at sign-in,
/// right down to which countries are listed and how search matches them.
struct CountryPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: CountryCode
    @State private var searchText = ""

    private var filtered: [CountryCode] {
        guard !searchText.isEmpty else { return CountryCode.all }
        return CountryCode.all.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.dialCode.contains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { country in
                Button {
                    selected = country
                    dismiss()
                } label: {
                    HStack {
                        Text(country.flag)
                        Text(country.name).foregroundStyle(.primary)
                        Spacer()
                        Text(country.dialCode).foregroundStyle(.secondary)
                        if country.id == selected.id {
                            Image(systemName: "checkmark").foregroundStyle(Color.brandForest)
                        }
                    }
                }
            }
            .navigationTitle("Country")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search countries")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

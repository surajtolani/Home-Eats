import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// Lets the family pin down exactly which brand/product they want for a
/// generic grocery item (e.g. which milk), with a photo attached so whoever
/// ends up shopping can match it on sight rather than guessing.
struct ProductOptionPickerView: View {
    let genericItemName: String
    var onSelect: (ProductOption?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allOptions: [ProductOption]

    @State private var showAddOption = false

    private var matchingOptions: [ProductOption] {
        let key = GroceryListBuilder.canonicalKey(for: genericItemName)
        return allOptions
            .filter { GroceryListBuilder.canonicalKey(for: $0.genericItemName) == key }
            .sorted { $0.brandName < $1.brandName }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        Label("No preference", systemImage: "questionmark.circle")
                    }
                }
                Section("Options for \"\(genericItemName)\"") {
                    if matchingOptions.isEmpty {
                        Text("No specific products saved yet.").foregroundStyle(.secondary)
                    }
                    ForEach(matchingOptions) { option in
                        Button {
                            onSelect(option)
                            dismiss()
                        } label: {
                            HStack {
                                ProductThumbnail(option: option, size: 44)
                                VStack(alignment: .leading) {
                                    Text(option.brandName).foregroundStyle(.primary)
                                    if let details = option.details, !details.isEmpty {
                                        Text(details).font(.brandCaption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose Product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showAddOption = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddOption) {
                AddProductOptionSheet(genericItemName: genericItemName) { newOption in
                    onSelect(newOption)
                    dismiss()
                }
            }
        }
    }
}

private struct AddProductOptionSheet: View {
    let genericItemName: String
    var onSave: (ProductOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var brandName = ""
    @State private var details = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoData: Data?

    var body: some View {
        NavigationStack {
            Form {
                Section("Product") {
                    TextField("Brand / product name", text: $brandName)
                    TextField("Details (size, notes)", text: $details)
                }
                Section("Photo") {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        if let photoData, let uiImage = UIImage(data: photoData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Label("Add a Photo", systemImage: "camera")
                        }
                    }
                }
            }
            .navigationTitle("New Product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(brandName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self) {
                        photoData = ImageResizing.downsized(data, maxDimension: 600)
                    }
                }
            }
        }
    }

    private func save() {
        let option = ProductOption(
            genericItemName: genericItemName,
            brandName: brandName.trimmingCharacters(in: .whitespaces),
            details: details.isEmpty ? nil : details,
            photoData: photoData
        )
        modelContext.insert(option)
        onSave(option)
        dismiss()
    }
}

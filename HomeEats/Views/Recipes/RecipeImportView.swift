import SwiftUI
import SwiftData

/// Paste-a-link recipe import. Fetches the page and reads its schema.org
/// JSON-LD recipe data; if a site doesn't publish that, the user is offered
/// a shortcut into the manual editor instead of a dead end.
struct RecipeImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var urlText: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var importedRecipe: Recipe?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste a recipe URL", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    } else {
                        Text("Works best with recipe blogs and cooking sites.")
                    }
                }

                if let importedRecipe {
                    Section("Preview") {
                        Text(importedRecipe.title).font(.headline)
                        Text("\(importedRecipe.ingredients.count) ingredients • \(importedRecipe.instructions.count) steps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Import Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if importedRecipe != nil {
                        Button("Save") { saveImported() }
                    } else {
                        Button {
                            Task { await fetchPreview() }
                        } label: {
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("Fetch")
                            }
                        }
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                    }
                }
            }
        }
    }

    private func fetchPreview() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            importedRecipe = try await RecipeImportService.importRecipe(from: urlText)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Something went wrong importing that link."
        }
    }

    private func saveImported() {
        guard let importedRecipe else { return }
        modelContext.insert(importedRecipe)
        dismiss()
    }
}

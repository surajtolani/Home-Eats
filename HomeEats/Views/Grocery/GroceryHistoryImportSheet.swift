import SwiftUI
import SwiftData

/// Bulk-populates the "past groceries" catalog by pasting in an old
/// shopping list — one item per line. Each line becomes a browsable,
/// one-tap-to-add item grouped by category at the bottom of the Grocery tab.
struct GroceryHistoryImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var existingItems: [HistoricalGroceryItem]

    @State private var pastedText = ""

    private var previewCount: Int {
        parsedLines(from: pastedText).count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $pastedText)
                        .frame(minHeight: 220)
                } header: {
                    Text("Paste Your Past Grocery List")
                } footer: {
                    Text("One item per line, e.g.\nMilk\nEggs\nPaper towels\nWe'll sort them by category automatically and skip anything you've already added.")
                }

                if previewCount > 0 {
                    Section {
                        Text("\(previewCount) new item(s) will be added.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add Past Groceries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { importItems() }
                        .disabled(previewCount == 0)
                }
            }
        }
    }

    private func parsedLines(from text: String) -> [String] {
        let existingKeys = Set(existingItems.map { GroceryListBuilder.canonicalKey(for: $0.name) })
        var seen = existingKeys
        var result: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let name = rawLine.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let key = GroceryListBuilder.canonicalKey(for: name)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(name)
        }
        return result
    }

    private func importItems() {
        for name in parsedLines(from: pastedText) {
            modelContext.insert(HistoricalGroceryItem(name: name))
        }
        dismiss()
    }
}

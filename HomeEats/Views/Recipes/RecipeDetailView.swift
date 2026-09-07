import SwiftUI
import SwiftData

struct RecipeDetailView: View {
    @Bindable var recipe: Recipe

    @Environment(\.modelContext) private var modelContext
    @State private var showEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let summary = recipe.summary, !summary.isEmpty {
                    Text(summary)
                        .foregroundStyle(.secondary)
                }

                metaRow

                VStack(alignment: .leading, spacing: 8) {
                    Text("Ingredients").font(.brandTitle3.bold())
                    ForEach(recipe.ingredients) { ingredient in
                        HStack(alignment: .top) {
                            Image(systemName: ingredient.category.symbolName)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(ingredient.displayText)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Instructions").font(.brandTitle3.bold())
                    ForEach(Array(recipe.instructions.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.brandHeadline)
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.accentColor))
                            Text(step)
                        }
                    }
                    if recipe.instructions.isEmpty {
                        Text("No steps added yet.").foregroundStyle(.secondary)
                    }
                }

                if let sourceURL = recipe.sourceURL, let url = URL(string: sourceURL) {
                    Link(destination: url) {
                        Label("View Original Recipe", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .padding()
        }
        .navigationTitle(recipe.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if recipe.source == .library && !recipe.isSavedToCollection {
                    Button("Save") {
                        recipe.isSavedToCollection = true
                    }
                } else {
                    Button("Edit") { showEditor = true }
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            RecipeEditorView(existing: recipe)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !recipe.tags.isEmpty {
                HStack {
                    ForEach(Array(recipe.tags.enumerated()), id: \.offset) { _, tag in
                        Text(tag)
                            .font(.brandCaption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 20) {
            Label("\(recipe.servings) servings", systemImage: "person.2")
            if recipe.prepMinutes > 0 {
                Label("\(recipe.prepMinutes)m prep", systemImage: "timer")
            }
            if recipe.cookMinutes > 0 {
                Label("\(recipe.cookMinutes)m cook", systemImage: "flame")
            }
        }
        .font(.brandSubheadline)
        .foregroundStyle(.secondary)
    }
}

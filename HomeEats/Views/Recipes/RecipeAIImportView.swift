import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// Adds a recipe from a photo (a recipe card, a cookbook page, a
/// screenshot, a handwritten note) and/or typed notes, instead of typing
/// the whole thing in by hand — backed by `ClaudeRecipeService`.
struct RecipeAIImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession
    /// Read-only, purely to back `duplicateMatch` below.
    @Query private var allRecipes: [Recipe]

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var notesText = ""
    @State private var isExtracting = false
    @State private var errorMessage: String?
    @State private var draft: RecipeDraft?
    /// Editable copies of `draft`'s fields, shown in editable form sections
    /// once extraction succeeds so the user can fix anything the AI got
    /// wrong (a misread ingredient quantity, a skipped step) before saving
    /// rather than after. `draft` itself just gates whether those sections
    /// (and the Save button) show at all; `saveDraft()` builds the saved
    /// `Recipe` from these edited fields, not from `draft` directly.
    @State private var draftTitle = ""
    @State private var draftSummary = ""
    @State private var draftServings = 4
    @State private var draftPrepMinutes = 0
    @State private var draftCookMinutes = 0
    @State private var draftIngredientsText = ""
    @State private var draftInstructionsText = ""
    @State private var showCamera = false
    /// Backs the "Add Anyway?" confirmation dialog — see
    /// `RecipeDuplicateChecker`'s own doc comment.
    @State private var showDuplicateConfirm = false

    /// Direct user request: "Recipes... should not be able to be added
    /// twice." A photo/notes import has no `sourceURL`, so this always
    /// falls back to a title match — see `RecipeDuplicateChecker`'s own
    /// doc comment.
    private var duplicateMatch: Recipe? {
        guard draft != nil else { return nil }
        return RecipeDuplicateChecker.existingMatch(title: draftTitle, sourceURL: nil, in: allRecipes)
    }

    private var canExtract: Bool {
        imageData != nil || !notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if !ClaudeRecipeService.isConfigured {
                    Section {
                        Text("AI recipe import isn't set up yet — see backend/README.md to enable it.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    if let imageData, let uiImage = UIImage(data: imageData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button("Remove Photo", role: .destructive) {
                            self.imageData = nil
                            selectedPhotoItem = nil
                        }
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            showCamera = true
                        } label: {
                            Label(imageData == nil ? "Take a Photo" : "Retake Photo", systemImage: "camera")
                        }
                    }
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label(imageData == nil ? "Choose From Library" : "Choose a Different Photo", systemImage: "photo.on.rectangle")
                    }
                } header: {
                    Text("Photo")
                } footer: {
                    // `allowsEditing` on the camera capture gives a built-in
                    // crop/rotate step — handy for trimming a whole cookbook
                    // page photo down to just the dish's own picture, and it
                    // also guarantees the result comes back right-side-up
                    // regardless of how the phone was held for the shot.
                    Text("Taking a photo lets you crop and straighten it right after — handy for a cookbook page where you only want the dish photo, not the whole spread.")
                }
                Section {
                    TextEditor(text: $notesText)
                        .frame(minHeight: 100)
                } header: {
                    Text("Or Type Notes")
                } footer: {
                    Text("A photo, notes, or both — whatever you've got works. \"Grandma's pancakes: 2 cups flour, 2 eggs, 1.5 cups milk, cook on a griddle\" is plenty.")
                        .font(.brandSubheadline)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                if draft != nil {
                    Section("Title") {
                        TextField("Title", text: $draftTitle)
                        TextField("Short description (optional)", text: $draftSummary)
                    }
                    Section("Details") {
                        Stepper("Servings: \(draftServings)", value: $draftServings, in: 1...20)
                        Stepper("Prep: \(draftPrepMinutes) min", value: $draftPrepMinutes, in: 0...240, step: 5)
                        Stepper("Cook: \(draftCookMinutes) min", value: $draftCookMinutes, in: 0...480, step: 5)
                    }
                    Section {
                        TextEditor(text: $draftIngredientsText)
                            .frame(minHeight: 140)
                    } header: {
                        Text("Ingredients")
                    } footer: {
                        Text("One ingredient per line — fix anything the extraction got wrong before saving.")
                            .font(.brandSubheadline)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        TextEditor(text: $draftInstructionsText)
                            .frame(minHeight: 160)
                    } header: {
                        Text("Instructions")
                    } footer: {
                        Text("One step per line.")
                            .font(.brandSubheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add from Photo or Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if draft != nil {
                        Button("Save") { attemptSaveDraft() }
                    } else if isExtracting {
                        ProgressView()
                    } else {
                        Button("Extract") {
                            Task { await extract() }
                        }
                        .disabled(!canExtract || !ClaudeRecipeService.isConfigured)
                    }
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self) {
                        // One downsized copy serves double duty: small enough
                        // to send to the vision endpoint quickly, and this
                        // same copy becomes the saved recipe's photo, so a
                        // photo-imported recipe gets a real thumbnail for
                        // free instead of the generic placeholder icon.
                        imageData = ImageResizing.downsized(data, maxDimension: 1000)
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraImagePicker { captured in
                    showCamera = false
                    guard let captured else { return }
                    selectedPhotoItem = nil
                    imageData = ImageResizing.downsized(captured, maxDimension: 1000)
                }
                .ignoresSafeArea()
            }
            .alert(
                "Already in Your Recipes",
                isPresented: $showDuplicateConfirm,
                presenting: duplicateMatch
            ) { _ in
                Button("Cancel", role: .cancel) {}
                Button("Add Anyway") { saveDraft() }
            } message: { match in
                Text("You already have a recipe called \"\(match.title)\". Add another one with the same name?")
            }
        }
    }

    private func extract() async {
        errorMessage = nil
        isExtracting = true
        defer { isExtracting = false }
        do {
            let extracted = try await ClaudeRecipeService.extractRecipe(imageData: imageData, notesText: notesText)
            draft = extracted
            draftTitle = extracted.title
            draftSummary = extracted.summary ?? ""
            draftServings = extracted.servings ?? 4
            draftPrepMinutes = extracted.prepMinutes ?? 0
            draftCookMinutes = extracted.cookMinutes ?? 0
            draftIngredientsText = extracted.ingredientLines.joined(separator: "\n")
            draftInstructionsText = extracted.instructions.joined(separator: "\n")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func attemptSaveDraft() {
        if duplicateMatch != nil {
            showDuplicateConfirm = true
        } else {
            saveDraft()
        }
    }

    private func saveDraft() {
        guard draft != nil else { return }
        // Built from the edited fields above, not `draft` itself — see
        // those `@State` properties' own doc comment for why.
        let recipe = Recipe(
            title: draftTitle.trimmingCharacters(in: .whitespaces),
            source: .manual,
            summary: draftSummary.isEmpty ? nil : draftSummary,
            instructions: draftInstructionsText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            ingredients: draftIngredientsText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map(IngredientLineParser.parse),
            servings: draftServings,
            prepMinutes: draftPrepMinutes,
            cookMinutes: draftCookMinutes,
            tags: ["AI"],
            createdByMemberID: activeUserSession.activeMemberID
        )
        recipe.photoData = imageData
        modelContext.insert(recipe)
        dismiss()
    }
}

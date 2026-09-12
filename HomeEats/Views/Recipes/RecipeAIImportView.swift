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

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var notesText = ""
    @State private var isExtracting = false
    @State private var errorMessage: String?
    @State private var draft: RecipeDraft?
    @State private var showCamera = false

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
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                if let draft {
                    Section("Preview") {
                        Text(draft.title).font(.brandHeadline)
                        if let summary = draft.summary, !summary.isEmpty {
                            Text(summary).font(.brandCaption).foregroundStyle(.secondary)
                        }
                        Text("\(draft.ingredientLines.count) ingredients, \(draft.instructions.count) steps")
                            .font(.brandCaption)
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
                        Button("Save") { saveDraft() }
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
        }
    }

    private func extract() async {
        errorMessage = nil
        isExtracting = true
        defer { isExtracting = false }
        do {
            draft = try await ClaudeRecipeService.extractRecipe(imageData: imageData, notesText: notesText)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveDraft() {
        guard let draft else { return }
        let recipe = draft.makeRecipe(createdByMemberID: activeUserSession.activeMemberID)
        recipe.photoData = imageData
        modelContext.insert(recipe)
        dismiss()
    }
}

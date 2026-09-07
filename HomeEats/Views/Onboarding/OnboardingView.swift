import SwiftUI
import SwiftData

/// Shown once, before any family members exist. Getting at least one person
/// named is the only thing the app truly needs before it's useful — meal
/// planning, suggestions, and grocery lists all key off `FamilyMember`.
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession

    @State private var entries: [NameEntry] = [NameEntry()]

    /// A stable identity per row, independent of position. Indexing into
    /// `names[index]` directly (the obvious first version of this screen)
    /// is a classic SwiftUI crash: removing a row can leave a `TextField`
    /// binding pointing at an index that's already out of range by the time
    /// SwiftUI re-diffs. Giving each row its own `UUID` and removing by that
    /// id sidesteps the whole class of bug.
    private struct NameEntry: Identifiable {
        let id = UUID()
        var text: String = ""
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "fork.knife.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text("Welcome to Home Eats")
                        .font(.title2.bold())
                    Text("Add everyone who'll be planning or eating meals. You can add more people any time from Settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)

                VStack(spacing: 12) {
                    ForEach($entries) { $entry in
                        HStack {
                            TextField("Name", text: $entry.text)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.words)
                            if entries.count > 1 {
                                Button(role: .destructive) {
                                    entries.removeAll { $0.id == entry.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    Button {
                        entries.append(NameEntry())
                    } label: {
                        Label("Add another person", systemImage: "plus.circle")
                    }
                }
                .padding(.horizontal)

                Spacer()

                Button {
                    createFamilyMembers()
                } label: {
                    Text("Get Started")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(entries.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty })
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func createFamilyMembers() {
        let palette = ["4E9F3D", "2E86AB", "E4572E", "9B5DE5", "F4A259", "168AAD"]
        var created: [FamilyMember] = []
        for (index, entry) in entries.enumerated() {
            let trimmed = entry.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let member = FamilyMember(name: trimmed, colorHex: palette[index % palette.count])
            modelContext.insert(member)
            created.append(member)
        }
        activeUserSession.setActive(created.first)
    }
}

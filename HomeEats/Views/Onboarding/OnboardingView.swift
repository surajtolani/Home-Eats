import SwiftUI
import SwiftData

/// Shown once, before any family members exist. Getting at least one person
/// named is the only thing the app truly needs before it's useful — meal
/// planning, suggestions, and grocery lists all key off `FamilyMember`.
struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession

    @State private var names: [String] = [""]

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
                    ForEach(names.indices, id: \.self) { index in
                        HStack {
                            TextField("Name", text: $names[index])
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.words)
                            if names.count > 1 {
                                Button(role: .destructive) {
                                    names.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    Button {
                        names.append("")
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
                .disabled(names.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func createFamilyMembers() {
        let palette = ["4E9F3D", "2E86AB", "E4572E", "9B5DE5", "F4A259", "168AAD"]
        var created: [FamilyMember] = []
        for (index, name) in names.enumerated() {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let member = FamilyMember(name: trimmed, colorHex: palette[index % palette.count])
            modelContext.insert(member)
            created.append(member)
        }
        activeUserSession.setActive(created.first)
    }
}

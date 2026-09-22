import SwiftUI
import SwiftData

struct FamilyMembersView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var activeUserSession: ActiveUserSession
    @Query(sort: \FamilyMember.createdAt) private var members: [FamilyMember]

    @State private var showAddSheet = false
    @State private var editingMember: FamilyMember?

    var body: some View {
        List {
            Section {
                ForEach(members) { member in
                    Button {
                        editingMember = member
                    } label: {
                        HStack {
                            MemberBadgeView(member: member, size: 32)
                            VStack(alignment: .leading) {
                                Text(member.name).foregroundStyle(.primary)
                                if member.isChild {
                                    Text("Kid").font(.brandCaption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if activeUserSession.activeMemberID == member.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        let member = members[index]
                        CascadeCleanup.removeVotes(fromMemberID: member.id, in: modelContext)
                        if activeUserSession.activeMemberID == member.id {
                            activeUserSession.setActive(members.first { $0.id != member.id })
                        }
                        modelContext.delete(member)
                    }
                }
            } footer: {
                Text("Tap a person to edit them. The checkmark shows who's currently active on this device — switch it from the badge in any tab's toolbar.")
                    .font(.brandSubheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Family")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            FamilyMemberEditorView()
        }
        .sheet(item: $editingMember) { member in
            FamilyMemberEditorView(existing: member)
        }
    }
}

private struct FamilyMemberEditorView: View {
    var existing: FamilyMember?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name: String
    @State private var isChild: Bool
    @State private var colorHex: String

    private static let palette = ["4E9F3D", "2E86AB", "E4572E", "9B5DE5", "F4A259", "168AAD", "D64550", "5C7457"]
    /// Human-readable names for `palette`, in the same order — a bare
    /// `Color(hex:)` swatch has nothing for VoiceOver to announce beyond
    /// "image" with no further description; these give each one a real
    /// accessibility label. Direct fix for a real gap: someone using
    /// VoiceOver had no way to tell these eight swatches apart at all.
    private static let paletteNames = ["Green", "Blue", "Orange Red", "Purple", "Peach", "Teal", "Red", "Olive"]

    init(existing: FamilyMember? = nil) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _isChild = State(initialValue: existing?.isChild ?? false)
        _colorHex = State(initialValue: existing?.colorHex ?? Self.palette.randomElement()!)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Toggle("Kid", isOn: $isChild)
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(Array(Self.palette.enumerated()), id: \.element) { index, hex in
                            let isSelected = hex == colorHex
                            // A `Button`, not a bare `.onTapGesture` (what
                            // this used to be) — a plain shape with a tap
                            // gesture isn't recognized as an interactive
                            // element by VoiceOver at all, let alone
                            // labeled, so this swatch grid was entirely
                            // unusable without sight.
                            Button {
                                colorHex = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        if isSelected {
                                            Image(systemName: "checkmark").foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Self.paletteNames[index])
                            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(existing == nil ? "New Family Member" : "Edit Member")
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
        let member = existing ?? FamilyMember(name: name)
        member.name = name.trimmingCharacters(in: .whitespaces)
        member.isChild = isChild
        member.colorHex = colorHex
        if existing == nil {
            modelContext.insert(member)
        }
        dismiss()
    }
}

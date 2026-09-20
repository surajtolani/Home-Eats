import SwiftUI

/// A toolbar control for switching which group's shared plan/grocery list
/// the main Plan and Grocery tabs render — the group-scoped equivalent of
/// `ActiveUserMenu` (see its own doc comment), now that groups, not
/// `FamilyMember`s, are what those tabs key off of. Used as the leading
/// item of `GroupTopBar` (see its own doc comment), the single shared static
/// top row both tabs place identically — this menu itself is unchanged
/// either way, since the behavior (list `activeGroupSession.groups`, check
/// off whichever matches `activeGroupID`, tap to switch) is identical
/// regardless of which tab it's attached to; only the content underneath
/// changes per tab.
///
/// Setting `activeGroupSession.activeGroupID` here is what actually drives
/// the switch: the Plan/Grocery tab content is keyed by
/// `.id(activeGroupSession.activeGroupID)` (see `RootView`), so this single
/// assignment is enough to tear down and freshly reload the other tab's
/// `GroupSharedMealPlanView`/`GroupSharedGroceryListView` for the
/// newly-active group — no separate "did the group change" plumbing needed
/// here.
///
/// **Small circular icon, not a text label** (per direct user request for
/// the top-bar redesign: "just a small circular icon on the left to select
/// your group"). A `GroupSummary` has no `colorHex`/avatar of its own (see
/// that type's own doc comment on what the wire shape actually carries), so
/// this shows the active group's own first initial in a plain tinted circle
/// instead — a lightweight way to visually tell groups apart at a glance
/// without inventing a color/avatar system this backend doesn't support —
/// falling back to a generic "people" glyph before any group is active yet.
///
/// **A real sheet with a `List`, not a native `Menu`** (changed from a
/// `Menu`-based picker) — direct user request: "on the right of each group
/// name, can you add an icon to allow you to quickly go in and look at the
/// members?" A `Menu`'s rows are single controls; there's no way to give a
/// row two independently-tappable regions (switch vs. view members)
/// inside one. `GroupSwitcherSheet` below is the replacement: each row is a
/// name (tap to switch, dismiss) plus a separate trailing "view members"
/// icon that pushes `GroupDetailView` right from this sheet. Rows are
/// ordered by `activeGroupSession.groupsByLastAccessed` — direct user
/// request: "can you sort by date last accessed?"
///
/// **Also where a new group gets created from**, per the same original
/// request ("should be able to also add a new group directly from here"):
/// a "Create New Group" row at the bottom of the sheet presents
/// `CreateGroupView` (`GroupsListView`'s own group-creation form, reused
/// as-is — see that view's own doc comment on why it's `internal`, not
/// `private`, specifically for reuse like this). On success, this
/// refreshes `activeGroupSession.groups` and switches straight to the
/// newly-created group — the same "don't land somewhere one tap further
/// away from what you just made" reasoning `GroupsListView`'s own
/// `newlyCreatedGroup` push already applies, just switching the active group
/// here instead of pushing a nav destination (there's no group-detail screen
/// to push into from a main tab's toolbar in the first place).
struct GroupSwitcherMenu: View {
    @EnvironmentObject private var activeGroupSession: ActiveGroupSession
    @State private var showSwitcher = false
    @State private var showCreateGroup = false

    var body: some View {
        Button {
            showSwitcher = true
        } label: {
            circularIcon
        }
        .accessibilityLabel("Switch active group")
        .sheet(isPresented: $showSwitcher) {
            GroupSwitcherSheet(onCreateNewGroup: {
                showCreateGroup = true
            })
        }
        .sheet(isPresented: $showCreateGroup) {
            CreateGroupView(onCreated: { created in
                Task {
                    await activeGroupSession.refreshGroups()
                    activeGroupSession.activeGroupID = created.id
                }
            })
        }
    }

    private var circularIcon: some View {
        ZStack {
            Circle().fill(Color.brandForest.opacity(0.15))
            if let initial = activeGroupSession.activeGroup?.name.trimmingCharacters(in: .whitespaces).first {
                Text(String(initial).uppercased())
                    .font(.brandCaption.bold())
                    .foregroundStyle(Color.brandForest)
            } else {
                Image(systemName: "person.3.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.brandForest)
            }
        }
        .frame(width: 30, height: 30)
    }
}

/// The switcher's actual content — see `GroupSwitcherMenu`'s own doc
/// comment for why this is a real sheet/`List` rather than a `Menu`.
///
/// **Compact sizing, not a full-height sheet** — direct user feedback that
/// the sheet felt "massive and misized" next to the compact `Menu` this
/// replaced. `.presentationDetents([.medium])` caps it at roughly half the
/// screen instead of the default near-full-height sheet, and every row uses
/// `.subheadline`/`.footnote` rather than a `List` row's default `.body`
/// text, closer to the original `Menu`'s own compact row size.
private struct GroupSwitcherSheet: View {
    let onCreateNewGroup: () -> Void

    @EnvironmentObject private var activeGroupSession: ActiveGroupSession
    @Environment(\.dismiss) private var dismiss
    /// Backs the "view members" tap — a plain `@State` + `.navigationDestination(item:)`
    /// push, not a `NavigationLink` embedded in the row. Direct user
    /// feedback: a `NavigationLink` anywhere in a `List` row makes SwiftUI
    /// add its own trailing disclosure chevron to that whole row
    /// automatically, even when the link is just one of two controls in an
    /// `HStack` — which duplicated with the `person.2` icon right next to
    /// it ("there's no difference between the right arrow... and the image
    /// for the icon"). Pushing programmatically instead means there's no
    /// `NavigationLink` anywhere in the row for `List` to notice, so no
    /// chevron gets added at all — just the one, intentional icon.
    @State private var pushedGroup: GroupSummary?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(activeGroupSession.groupsByLastAccessed) { group in
                        groupRow(group)
                    }
                }
                Section {
                    Button {
                        // Dismiss this sheet first, then ask the parent to
                        // present `CreateGroupView` — presenting a second
                        // sheet from a view already inside one doesn't
                        // work; the parent's own `.sheet` (a sibling of
                        // this one, not nested inside it) is what actually
                        // shows it, right after this one finishes closing.
                        dismiss()
                        onCreateNewGroup()
                    } label: {
                        Label("Create New Group", systemImage: "plus.circle")
                            .font(.subheadline)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Switch Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $pushedGroup) { group in
                GroupDetailView(groupID: group.id, groupName: group.name)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func groupRow(_ group: GroupSummary) -> some View {
        HStack {
            Button {
                activeGroupSession.activeGroupID = group.id
                dismiss()
            } label: {
                HStack {
                    if activeGroupSession.activeGroupID == group.id {
                        Image(systemName: "checkmark")
                            .font(.footnote)
                            .foregroundStyle(Color.brandForest)
                    }
                    Text(group.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The "quickly go in and look at the members" ask — a separate
            // tap target from the row's own switch-to-this-group action
            // above, not nested inside it (see this file's own doc comment
            // on why a `Menu` couldn't do this at all). A plain `Button`
            // setting `pushedGroup`, not a `NavigationLink` — see that
            // property's own doc comment for why.
            Button {
                pushedGroup = group
            } label: {
                Image(systemName: "person.2")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(group.name) members")
        }
    }
}

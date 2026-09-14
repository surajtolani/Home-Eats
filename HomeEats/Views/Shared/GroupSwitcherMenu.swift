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
/// **Also where a new group gets created from**, per the same request
/// ("should be able to also add a new group directly from here"): a
/// "Create New Group" entry at the bottom of the menu presents
/// `CreateGroupView` (`GroupsListView`'s own group-creation form, reused
/// as-is — see that view's own doc comment on why it's `internal`, not
/// `private`, specifically for reuse like this) as a sheet. On success, this
/// refreshes `activeGroupSession.groups` and switches straight to the
/// newly-created group — the same "don't land somewhere one tap further
/// away from what you just made" reasoning `GroupsListView`'s own
/// `newlyCreatedGroup` push already applies, just switching the active group
/// here instead of pushing a nav destination (there's no group-detail screen
/// to push into from a main tab's toolbar in the first place).
struct GroupSwitcherMenu: View {
    @EnvironmentObject private var activeGroupSession: ActiveGroupSession
    @State private var showCreateGroup = false

    var body: some View {
        Menu {
            ForEach(activeGroupSession.groups) { group in
                Button {
                    activeGroupSession.activeGroupID = group.id
                } label: {
                    if activeGroupSession.activeGroupID == group.id {
                        Label(group.name, systemImage: "checkmark")
                    } else {
                        Text(group.name)
                    }
                }
            }
            Divider()
            Button {
                showCreateGroup = true
            } label: {
                Label("Create New Group", systemImage: "plus.circle")
            }
        } label: {
            circularIcon
        }
        .accessibilityLabel("Switch active group")
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

import SwiftUI

/// A toolbar control for switching which group's shared plan/grocery list
/// the main Plan and Grocery tabs render — the group-scoped equivalent of
/// `ActiveUserMenu` (see its own doc comment), now that groups, not
/// `FamilyMember`s, are what those tabs key off of. Shared between both
/// tabs (`RootView` places one instance of this in each tab's
/// `NavigationStack` toolbar) rather than built twice, since the behavior —
/// list `activeGroupSession.groups`, check off whichever matches
/// `activeGroupID`, tap to switch — is identical either way; only the
/// content underneath changes per tab.
///
/// Setting `activeGroupSession.activeGroupID` here is what actually drives
/// the switch: the Plan/Grocery tab content is keyed by
/// `.id(activeGroupSession.activeGroupID)` (see `RootView`), so this single
/// assignment is enough to tear down and freshly reload the other tab's
/// `GroupSharedMealPlanView`/`GroupSharedGroceryListView` for the
/// newly-active group — no separate "did the group change" plumbing needed
/// here.
struct GroupSwitcherMenu: View {
    @EnvironmentObject private var activeGroupSession: ActiveGroupSession

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
        } label: {
            // No per-group avatar/color the way `MemberBadgeView` has for a
            // `FamilyMember` (a group has no `colorHex` — see
            // `GroupSummary`'s doc comment on what the wire shape actually
            // carries) — a plain label naming the active group, with a
            // chevron making clear it's tappable, reads clearly enough
            // without one for the handful of groups this is meant to
            // scale to.
            HStack(spacing: 4) {
                Image(systemName: "person.3.fill")
                Text(activeGroupSession.activeGroup?.name ?? "Select Group")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(Color.brandForest)
        }
        .accessibilityLabel("Switch active group")
    }
}

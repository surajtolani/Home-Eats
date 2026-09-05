import SwiftUI
import SwiftData

/// A toolbar control for switching "who's using the app right now" on a
/// shared household device. Whoever is active gets attributed on any
/// suggestion, vote, or decision made while they're selected.
struct ActiveUserMenu: View {
    @Query(sort: \FamilyMember.createdAt) private var members: [FamilyMember]
    @EnvironmentObject private var activeUserSession: ActiveUserSession

    var body: some View {
        Menu {
            ForEach(members) { member in
                Button {
                    activeUserSession.setActive(member)
                } label: {
                    Label(member.name, systemImage: activeUserSession.activeMemberID == member.id ? "checkmark" : "")
                }
            }
        } label: {
            if let active = members.first(where: { $0.id == activeUserSession.activeMemberID }) {
                MemberBadgeView(member: active, size: 28)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        .accessibilityLabel("Switch active family member")
    }
}

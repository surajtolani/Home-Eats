import Foundation
import SwiftUI

/// Tracks "who's using the app right now" on a shared household device, so
/// suggestions/votes/decisions can be attributed to the right family member
/// without requiring separate logins. Persisted locally (UserDefaults) so
/// switching back to the app remembers the last person who was using it.
@MainActor
final class ActiveUserSession: ObservableObject {
    private static let storageKey = "activeFamilyMemberID"

    @Published var activeMemberID: UUID? {
        didSet {
            if let activeMemberID {
                UserDefaults.standard.set(activeMemberID.uuidString, forKey: Self.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.storageKey)
            }
        }
    }

    init() {
        if let stored = UserDefaults.standard.string(forKey: Self.storageKey),
           let uuid = UUID(uuidString: stored) {
            activeMemberID = uuid
        } else {
            activeMemberID = nil
        }
    }

    func setActive(_ member: FamilyMember?) {
        activeMemberID = member?.id
    }
}

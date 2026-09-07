import SwiftUI

/// A small colored initial-badge for a family member, used throughout the
/// app so a suggestion or decision's "who" is visible at a glance.
struct MemberBadgeView: View {
    let member: FamilyMember
    var size: CGFloat = 24

    var body: some View {
        Text(initials)
            .font(.custom("Nunito-SemiBold", size: size * 0.42))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hex: member.colorHex)))
    }

    private var initials: String {
        let parts = member.name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }
}

extension Color {
    /// Builds a Color from a "RRGGBB" hex string, falling back to gray.
    init(hex: String) {
        var hexValue: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard Scanner(string: cleaned).scanHexInt64(&hexValue), cleaned.count == 6 else {
            self = .gray
            return
        }
        let r = Double((hexValue & 0xFF0000) >> 16) / 255
        let g = Double((hexValue & 0x00FF00) >> 8) / 255
        let b = Double(hexValue & 0x0000FF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

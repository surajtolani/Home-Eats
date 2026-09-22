import SwiftUI

/// The four meal-plan status categories the Plan tab's calendar dots (and
/// legend) surface for a day — home-cooked, eating out, order in, or a
/// still-pending suggestion. Each carries both a color AND a shape.
///
/// Direct fix for a real accessibility finding: these dots used to be
/// color-only circles, and three of the four colors (a deep green, a warm
/// orange-red, and an amber) all sit in the same hue family that's hardest
/// to tell apart under red-green color blindness — the most common form.
/// Shape now carries the primary signal (a circle reads differently from a
/// square, diamond, or triangle regardless of color perception); color is
/// still distinct where possible, but no longer the only cue.
enum MealStatusKind {
    case homeCooked
    case eatingOut
    case orderingIn
    case suggested

    var color: Color {
        switch self {
        case .homeCooked: return .brandForest
        case .eatingOut: return .brandTerracotta
        case .orderingIn: return .brandHoney
        case .suggested: return .brandBlush
        }
    }

    var label: String {
        switch self {
        case .homeCooked: return "Cooking"
        case .eatingOut: return "Eating out"
        case .orderingIn: return "Order in"
        case .suggested: return "Suggested"
        }
    }
}

/// One filled shape for a `MealStatusKind`, sized to fit a small calendar
/// dot or legend swatch. Used by both the personal Plan tab's calendar
/// (`CalendarPlanView`) and the group shared plan's identical one
/// (`GroupSharedMealPlanView`) — one shape/color mapping for both, rather
/// than two copies that could drift apart.
struct MealStatusDot: View {
    let kind: MealStatusKind
    var size: CGFloat = 6

    var body: some View {
        shape
            .fill(kind.color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    // `AnyShape` (not `@ViewBuilder`, which builds `View`s, not `Shape`s) —
    // each case is a different concrete `Shape` type, so this needs real
    // type erasure to return one common type.
    private var shape: AnyShape {
        switch kind {
        case .homeCooked: AnyShape(Circle())
        case .eatingOut: AnyShape(Rectangle())
        case .orderingIn: AnyShape(MealStatusDiamond())
        case .suggested: AnyShape(MealStatusTriangle())
        }
    }
}

private struct MealStatusDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

private struct MealStatusTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

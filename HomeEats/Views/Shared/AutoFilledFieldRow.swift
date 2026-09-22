import SwiftUI

/// A read-only `Form`/`List` row for a value that's only ever set by
/// picking something elsewhere (never typed directly) — currently just the
/// profile's State field, auto-filled from `CitySearchField`'s Google
/// Places lookup (`ProfileCompletionStepView`, `EditProfileView`). Reads the
/// same as a disabled `Picker`/settings row: a label on the left, the
/// current value (or a hint, when empty) on the right, no way to tap into
/// it directly.
struct AutoFilledFieldRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value.isEmpty ? "Pick a city above" : value)
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
        }
    }
}

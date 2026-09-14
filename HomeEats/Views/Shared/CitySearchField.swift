import SwiftUI

/// A city text field that becomes a real search-as-you-type field once
/// `GooglePlacesService.isConfigured` — type a few letters, get live city
/// suggestions from Google, tap one, and this hands back the resolved
/// state/country for that city too (not just the city name itself) via
/// `onCityDetails`. Built for the profile's City field
/// (`ProfileCompletionStepView`, `EditProfileView`) — direct follow-up to
/// State/Country becoming `Picker`s from fixed lists there: "That way it
/// pre-populates everything once you select the right one."
///
/// **The city text itself is always driven by `text` directly** — tapping a
/// suggestion sets `text` to that suggestion's own display name
/// immediately, synchronously, before the separate, billed Place Details
/// call that resolves state/country even starts. That's deliberate: a
/// suggestion's `mainText` is always present (it's what populated the
/// dropdown row in the first place), unlike `CityDetails.city`, which
/// Google's Place Details response can legitimately omit for a given place
/// (see `GooglePlacesService.CityDetails`'s doc comment) — driving the text
/// field from the guaranteed value, rather than the one that can come back
/// `nil`, is what makes "fill cityInput always" actually guaranteed, not
/// just usually true.
///
/// `onCityDetails` fires once per tapped suggestion, after the Details call
/// resolves — same "hand back a value, caller decides what to do with it"
/// convention as `ContactOrPhoneNumberPickerView`'s `onPick` and
/// `CountryPickerSheet`'s `selected` binding elsewhere in this codebase.
/// Each field on the `CityDetails` it hands back can legitimately be `nil`;
/// the caller is expected to only overwrite its own State/Country selection
/// when the corresponding field is non-nil (see the two call sites) — never
/// blank out a Picker the user already touched just because Google's
/// response happened to omit that one field for this particular place.
/// Never called at all if the Details lookup itself fails (network error,
/// bad place id) — `text` was already set from the suggestion by then
/// regardless, so a selection that fails to resolve still leaves City
/// filled in, just without State/Country coming along with it.
///
/// Also works as a perfectly ordinary text field, with no dropdown and no
/// network calls attempted at all, when `GooglePlacesService.isConfigured`
/// is false (no backend URL configured) — falling back to ordinary free
/// typing rather than showing a dropdown that could never return anything.
/// Free typing that never triggers a selection at all — because the app
/// isn't configured, or because someone's actual town just doesn't turn up
/// in results — is always available and always counts as a filled-in City,
/// exactly as it did before this field existed: nothing here requires a
/// dropdown selection to consider the field "filled."
struct CitySearchField: View {
    @Binding var text: String
    var onCityDetails: (GooglePlacesService.CityDetails) -> Void

    @StateObject private var model = CitySearchModel()
    /// Set right before `select(_:)` programmatically assigns `text` to a
    /// tapped suggestion's own name, and checked (then reset) at the very
    /// top of `.onChange(of: text)` below — without this, that assignment
    /// looks identical to the user having typed it, since `.onChange`
    /// fires for a `@Binding` mutation regardless of where it came from.
    /// Left unguarded, tapping a suggestion set off a *second* search for
    /// the name just selected, which ~300ms later (the debounce) reopened
    /// the dropdown right after it had just been dismissed — a real,
    /// confusing "it closes and immediately pops back open" bug found by
    /// tracing through this exact sequence, not reported from a device.
    @State private var isProgrammaticTextChange = false
    /// The dropdown only ever renders while this field actually has
    /// keyboard focus — belt-and-suspenders alongside
    /// `isProgrammaticTextChange` above, and the one guard that also covers
    /// a case that flag can't: both call sites pre-fill `text` from an
    /// already-saved profile in their own `.onAppear` (`loadCurrentValues`
    /// setting `cityInput = user.city ?? ""`), which is exactly as
    /// "programmatic" a change as a tapped suggestion is, but happens
    /// somewhere else entirely (a sibling/parent view's `.onAppear`, not
    /// this type's own `select(_:)`) — nothing here can reliably know that
    /// mutation is about to happen ahead of time, or prove it always runs
    /// before or after this view's own first render. Gating strictly on
    /// focus sidesteps the whole ordering question: whatever set `text`
    /// before the user ever tapped into this field, a `model.search(...)`
    /// firing for it in the background is harmless as long as its results
    /// never actually get shown before real typing puts them there.
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            TextField("City", text: $text)
                .textContentType(.addressCity)
                .focused($isFocused)
                .onChange(of: text) { _, newValue in
                    if isProgrammaticTextChange {
                        isProgrammaticTextChange = false
                        return
                    }
                    guard GooglePlacesService.isConfigured else { return }
                    model.search(newValue)
                }

            if GooglePlacesService.isConfigured && isFocused {
                if model.isSearching {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if !model.suggestions.isEmpty {
                    ForEach(model.suggestions) { suggestion in
                        Button {
                            select(suggestion)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.mainText)
                                    .foregroundStyle(.primary)
                                if let secondaryText = suggestion.secondaryText {
                                    Text(secondaryText)
                                        .font(.brandCaption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func select(_ suggestion: GooglePlacesService.CitySuggestion) {
        // Drop focus too, not just the flag below — belt-and-suspenders
        // with the `isFocused`-gated dropdown visibility above: this alone
        // already hides the dropdown and dismisses the keyboard the moment
        // a row is tapped, and it's what keeps a late-arriving (already-
        // cancelled, but never say never) search response from ever
        // rendering after a selection, on top of `isProgrammaticTextChange`
        // preventing that response from being fetched again in the first
        // place.
        isFocused = false
        // `isProgrammaticTextChange = true` BEFORE the assignment below —
        // see that property's own doc comment for exactly what this
        // prevents (a reopened dropdown right after tapping a suggestion).
        isProgrammaticTextChange = true
        // Set first, synchronously — see this type's own doc comment on why
        // the text field's fill is driven from the suggestion's own text,
        // not from whatever Details comes back with (or doesn't).
        text = suggestion.mainText
        model.clearSuggestions()
        Task {
            await model.resolveDetails(placeID: suggestion.placeID, onResolved: onCityDetails)
        }
    }
}

/// The debounce + network state behind `CitySearchField` — a separate
/// `ObservableObject` (rather than plain `@State` in the view) purely so
/// the in-flight search `Task` survives across body re-evaluations, the
/// same reason `RestaurantSearchModel` in `RestaurantListView.swift` is its
/// own object rather than view-local state. The debounce value (300ms) and
/// the cancel-the-previous-task-before-starting-a-new-one structure are
/// copied from `RestaurantSearchModel.search` directly rather than
/// reinvented, so both search-as-you-type fields in this app behave
/// identically from a typing feel standpoint.
@MainActor
private final class CitySearchModel: ObservableObject {
    @Published var suggestions: [GooglePlacesService.CitySuggestion] = []
    @Published var isSearching = false

    private var searchTask: Task<Void, Never>?

    func search(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            suggestions = []
            return
        }
        searchTask = Task {
            // Small debounce so a search isn't fired on every keystroke —
            // same 300ms as RestaurantSearchModel.search.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            isSearching = true
            defer { isSearching = false }
            do {
                let results = try await GooglePlacesService.searchCities(trimmed)
                guard !Task.isCancelled else { return }
                suggestions = results
            } catch {
                guard !Task.isCancelled else { return }
                // A failed lookup just means no dropdown shows — the field
                // is still a perfectly usable plain text field either way
                // (see CitySearchField's own doc comment on falling back to
                // free typing), so this doesn't need to surface as a
                // visible error the way a deliberate, user-initiated search
                // failure does elsewhere in this app (e.g.
                // RestaurantSearchModel.errorMessage).
                suggestions = []
            }
        }
    }

    /// Collapses the dropdown immediately after a tap, before the separate
    /// Details call below even starts — so the row that was just tapped
    /// doesn't stay visible mid-resolve, and cancels any still-in-flight
    /// search task so a slow Autocomplete response can't repopulate the
    /// dropdown right after it was just cleared.
    func clearSuggestions() {
        searchTask?.cancel()
        suggestions = []
    }

    /// Resolves one tapped suggestion into `{ city, state, country }` and
    /// hands it to `onResolved` — see `CitySearchField.onCityDetails`'s doc
    /// comment for the full contract. Swallows a failed lookup rather than
    /// surfacing an error: the city text was already set from the
    /// suggestion before this was ever called (`CitySearchField.select`
    /// sets `text` first), so there's nothing broken for the user to see —
    /// just a selection that didn't happen to bring State/Country along.
    func resolveDetails(
        placeID: String,
        onResolved: (GooglePlacesService.CityDetails) -> Void
    ) async {
        // Explicit do/catch rather than `try? await ... ?? fallback` — this
        // codebase avoids `??` with `await` on its right-hand side (a
        // previously-fixed bug class), and there's no meaningful fallback
        // value here anyway: a failure just means `onResolved` isn't called
        // at all.
        do {
            let details = try await GooglePlacesService.cityDetails(placeID: placeID)
            onResolved(details)
        } catch {
            // See doc comment above — deliberately silent.
        }
    }
}

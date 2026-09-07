# Home Eats

A native iPhone app for family meal planning, grocery management, and
coordination — built with SwiftUI + SwiftData, local-first, no account
required.

This repo is the first build-out of the app described in the project spec
(recipe input, a browsable recipe library, day-by-day meal planning with
multi-person suggestions/voting, restaurant/eating-out planning, a
configurable weekly planning reminder, an auto-generated grocery list, and
meal history-based recommendations). It's a solid MVP scaffold, not a
finished product — see **Known limitations & next steps** below.

## Requirements

- macOS with Xcode 15 or newer (iOS 17 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the
  `.xcodeproj` from `project.yml` (the project file itself isn't checked in —
  see `.gitignore` — so it can't go stale relative to the source list)

```bash
brew install xcodegen
```

## Building & running

```bash
cd Home-Eats
xcodegen generate
open HomeEats.xcodeproj
```

Then in Xcode:
1. Select the `HomeEats` scheme.
2. Set your signing team under the target's *Signing & Capabilities* tab
   (needed to run on a physical device; the simulator doesn't require one).
3. Build & run on an iPhone simulator or device (iOS 17+).

Run the test target with `cmd-U`, or `xcodebuild test -scheme HomeEats
-destination 'platform=iOS Simulator,name=iPhone 15'` from the CLI.

> The app ships with a placeholder `AppIcon` entry with no actual image —
> drop real 1024×1024 artwork into
> `HomeEats/Resources/Assets.xcassets/AppIcon.appiconset` before shipping.

## Architecture

```
HomeEats/
  App/            App entry point, ModelContainer setup, cross-cutting session state
  Models/         SwiftData @Model types (see below)
  Services/       Pure logic: grocery aggregation, recipe import/parsing,
                  notification scheduling, recommendations, seed data
  Views/          SwiftUI screens, grouped by feature area
  Resources/      Asset catalog + bundled recipe library JSON
HomeEatsTests/    Unit tests for the Services layer
```

**Storage** is local-only via SwiftData (`ModelConfiguration(cloudKitDatabase:
.none)` in `HomeEatsApp.swift`), so the app works fully offline and needs no
account, per the spec. The models:

| Model | Purpose |
|---|---|
| `FamilyMember` | A person in the household; every suggestion/decision is attributed to one. |
| `Recipe` | Manual, imported, or built-in-library recipe: title, ingredients, step-by-step instructions. |
| `RecipeIngredientEntry` | A parsed ingredient line (qty/unit/name/category) — a value type embedded on `Recipe`, not its own table. |
| `Restaurant` | An eating-out *or* order-in option, assignable to a meal slot like a recipe. Carries an address for the map + Google Maps link, plus the household's own price range/rating (not pulled from Google — see below). |
| `MealSlot` | Not a table — an enum (breakfast/lunch/dinner/other) that scopes `PlannedMeal` and `MealSuggestion` to a specific meal within a day. |
| `PlannedMeal` | One decided meal for a (date, slot) — a recipe, or a restaurant either dined at (`isOrderIn: false`) or ordered from (`isOrderIn: true`). A slot can hold more than one (a dinner plan *and* a separate ice-cream-run entry both fit). |
| `MealSuggestion` | A family member's proposal for a (date, slot), with a lightweight up-vote list. |
| `GroceryItem` | A generated (or manually added) shopping list line for a given week, with checked state and chosen product. |
| `ProductOption` | A specific brand/product for a generic grocery item, with a photo, so the shopper can match it on sight. |
| `StapleItem` | The household's standing "regular items" list (the notepad-on-the-fridge replacement). |
| `MealHistoryEntry` | A record that a meal actually happened (separate from planning), feeding the recommendation engine. |
| `AppSettings` | Singleton row: reminder day/time, household name, sync toggle placeholder. |
| `StoreAisle` | A user-defined aisle in the household's actual grocery store, in walking order. |
| `ItemAisleAssignment` | Which aisle a canonical item name belongs in — persists across weeks. |
| `HistoricalGroceryItem` | The "past groceries" catalog (populated by pasting an old list) for one-tap re-adding. |

**Services** worth knowing about:
- `GroceryListBuilder` aggregates ingredients across a week's home-cooked
  meals (any slot), merges duplicates (simple plural-insensitive name matching),
  splits into a "this week" section and a "staples" section, and sorts by
  store category.
- `RecipeImportService` / `SchemaOrgRecipeParser` fetch a pasted URL and read
  its embedded schema.org `Recipe` JSON-LD (what most recipe sites publish
  for SEO rich snippets) — no full HTML parser needed. `SchemaOrgRecipeParser`
  is the pure/testable half; `RecipeImportService` just adds networking.
- `RecommendationEngine` ranks recipes by recency-weighted frequency from
  `MealHistoryEntry`, per the spec's "start simple" guidance — no ML.
- `NotificationScheduler` + `PlanningReminderRouter` schedule the configurable
  weekly reminder and route a tap straight into `PlanningReminderFlowView`.
- `SampleDataSeeder` seeds the built-in recipe library
  (`Resources/Seed/BuiltInRecipes.json`), a starter staples list, and the
  settings singleton on first launch.

**Multi-user on one device**: rather than separate logins, `ActiveUserSession`
tracks "who's using the app right now" (persisted in `UserDefaults`),
switchable from a badge in the toolbar. Every suggestion, vote, and decision
records that person's ID, so a weekend preference and a weekday preference
stay visibly attributed even on a single shared phone.

## Branding

The app icon, color palette, and typography match the Home Eats brand
guidelines sheet:

- **App icon** — `Resources/Assets.xcassets/AppIcon.appiconset` (single
  1024×1024 universal image; Xcode/iOS generate every other size and apply
  corner rounding themselves — never add a pre-rounded icon).
- **Colors** — `Resources/Assets.xcassets` has one color asset per palette
  color (`BrandOlive`, `BrandForest`, `BrandSage`, `BrandCream`,
  `BrandTerracotta`, `BrandHoney`, `BrandBlush`, `BrandSand`), exposed as
  `Color.brandOlive` etc. via `Theme/BrandTheme.swift`. `AccentColor` is set
  to the same value as `BrandOlive`, which is what makes tab selection,
  links, and default button/control tint all pick up the brand green with no
  per-view code. These are fixed brand colors (not light/dark adaptive) —
  intentional, since the guidelines define one palette, not two. Because of
  that, `HomeEatsApp` also pins the whole app to `.preferredColorScheme(.light)`
  — without it, system-drawn chrome that isn't ours to theme (the search bar,
  the keyboard, sheets) still follows the device's Dark Mode setting on its
  own, producing a visible seam against the fixed-light nav bar/tab bar/list
  background right next to it. Revisit both together if the brand ever gets
  a real dark variant.
- **Typography** — Nunito (`Resources/Fonts/*.ttf`, registered via
  `UIAppFonts` in `project.yml`), exposed as a `Font.brand*` scale
  (`brandLargeTitle` … `brandCaption2`) in `Theme/BrandTheme.swift` that
  mirrors the system Dynamic Type styles it replaces, `relativeTo:` included,
  so Dynamic Type/accessibility sizing still works. `HomeEatsApp` sets
  `.environment(\.font, .brandBody)` as the app-wide default, and every
  `.font(.headline)`-style call site in `Views/` was switched to its
  `.brand*` equivalent. `Theme/BrandAppearance.apply()` (called once from
  `HomeEatsApp.init()`) applies the same look to UIKit-drawn chrome
  (nav bar, tab bar, list background) that SwiftUI's `.font`/`.tint`
  modifiers can't reach.
- The Nunito `.ttf` files are static instances repackaged from
  [`@fontsource/nunito`](https://www.npmjs.com/package/@fontsource/nunito)
  (SIL Open Font License) — free to bundle in the app.

## Feature → spec mapping

1. **Recipe input** — `RecipeEditorView` (manual) and `RecipeImportView` +
   `RecipeImportService` (paste a URL).
2. **Recipe library** — `RecipesHomeView`'s "Library" tab, seeded from
   `BuiltInRecipes.json`; "Save" copies a library recipe into "My Recipes"
   without duplicating data (`Recipe.isSavedToCollection`).
3. **Day-by-day, meal-by-meal planning** — `CalendarPlanView` offers two
   ways to look at the plan: **Calendar** (a month grid, past days dimmed,
   tap a date to anchor an agenda list below showing that date and every day
   after it) and **This Week** (a flat agenda of just the current 7 days).
   Tapping into a day opens `DayDetailView`, broken into Breakfast / Lunch /
   Dinner / Other — each slot holds any number of `PlannedMeal`s, so "Dinner:
   Tacos" and a separate "Other: Ice cream run" both fit on the same day,
   and multiple undecided options can sit side by side before the family
   settles on one.
4. **Restaurant planning** — `RestaurantListView` has a search bar up top
   (Apple's free `MKLocalSearch`, no API key) that looks up real places by
   name; tap **+** on a result to add it straight to the restaurant list with
   its address filled in, or add one manually via the toolbar.
   `RestaurantEditorView` / `RestaurantDetailView` round it out — restaurants
   are first-class, assignable to a meal slot exactly like a recipe. The
   detail view geocodes the address into an embedded MapKit map and a button
   opens the same place in Google Maps for reviews/photos, which Apple's free
   maps APIs don't expose.
5. **Planning notifications** — `SettingsView` configures day/time;
   `NotificationScheduler` schedules it; tapping it opens
   `PlanningReminderFlowView`, a day-by-day wizard over the upcoming week's
   still-undecided *dinners* (the meal a weekly planning session is really
   about), with a link out to the full day view for breakfast/lunch/other.
6. **Grocery list generation** — `GroceryListView` + `GroceryListBuilder`;
   category grouping, duplicate merging, a staples section
   (`StaplesManagerView`), and per-item brand/product selection with a photo
   (`ProductOptionPickerView`, backed by `PhotosPicker`). A segmented control
   switches the list between "By Category" and **"My Grocery Layout"**
   (`AislesManagerView` + drag-and-drop via the classic `NSItemProvider`-based
   `.onDrag`/`.onDrop`),
   which lays items out by the household's own store aisles instead — drag an
   item from "Unsorted" onto an aisle to place it there for good
   (`ItemAisleAssignment`, keyed by canonical item name so it persists across
   weeks). A **"From Your Past Groceries"** section at the bottom
   (`HistoricalGroceryItem`) lists everything you've bought before, grouped by
   category, with a one-tap **+** to add it to this week's list; populate it in
   bulk by pasting an old list (`GroceryHistoryImportSheet`).
7. **Cooking guidance** — `RecipeDetailView` shows numbered step-by-step
   instructions. Imported ingredient lines are reformatted consistently
   (`RecipeIngredientEntry.displayText`, `IngredientLineParser`) rather than
   shown verbatim from the source site — unicode fraction glyphs ("½"),
   non-breaking spaces, and double-spacing all normalize to a single clean
   "1 1/2 cups flour" style line, since raw source formatting was hard to
   read at a glance (was it a half, a one, or a two?).
8. **Meal history & recommendations** — `MealHistoryView` logs what was
   actually made (from a day's plan via `LogMealSheet`, or manually);
   `RecommendationEngine` surfaces frequency/recency favorites when picking a
   recipe for a day.

## Known limitations & next steps

This is a first build-out, scoped per the spec's own phasing notes:

- **⚠️ Local storage resets on this update.** This round changed the SwiftData
  schema (`DayPlan` → `PlannedMeal`/`MealSlot`) in a way lightweight migration
  can't bridge, and also moved the on-disk store to an explicit path so a
  failed-migration launch can recover instead of crashing forever
  (`HomeEatsApp.swift`). Net effect: on-device data from before this commit —
  family members, saved recipes, everything — is gone, and onboarding runs
  again. Acceptable now (no real users yet); shipping a schema change like
  this for real would need an actual `SchemaMigrationPlan`, not a reset.
- **Two independent review passes found and fixed real bugs after the
  meal-slot refactor** (double-check + red-team agents, `27ccd3f1..HEAD`):
  two crashes (`Dictionary(uniqueKeysWithValues:)` trapping on duplicate
  staple names, `Int(Double)` trapping on a garbled/huge parsed quantity),
  the weekly-planning wizard's "Skip" button being dead code and the
  reminder notification never actually being scheduled, deleting a
  Recipe/Restaurant/FamilyMember orphaning `PlannedMeal`/`MealSuggestion`
  references, an index-out-of-bounds risk on the onboarding screen, a unit
  (cup vs. cups) that silently failed to combine in the grocery list, and a
  fraction (⅖, ⅗, ...) that displayed as the *wrong* nearby fraction. See
  the commit for the full list — this is the kind of review worth repeating
  after any large refactor.
- **Cloud sync is not implemented.** The settings screen has a disabled
  placeholder toggle; wiring it up means switching
  `ModelConfiguration(cloudKitDatabase:)` to `.automatic`, enabling the
  iCloud/CloudKit capability in Xcode, and making every model's relationships
  CloudKit-compatible (all-optional relationship targets, no unique
  constraints on non-id fields — worth a pass before flipping this on).
- **Multi-user is single-device today** (`ActiveUserSession`), matching the
  spec's suggested first phase; true per-person multi-device sync would ride
  on top of the CloudKit work above.
- **Ingredient parsing/merging is heuristic** (regex quantity/unit parsing,
  naive plural stripping), which is intentionally the "start simple" version
  the spec calls for — it'll misparse unusual phrasing and won't merge every
  synonym (e.g. "scallion" vs. "green onion").
- **URL import depends on a site publishing schema.org JSON-LD.** Most
  recipe blogs do; sites that don't will fall through to
  `RecipeImportError.noRecipeFound`, and the user is pointed at the manual
  editor instead.
- **No bundled product photos.** Product photos are added by the user via
  `PhotosPicker` when creating a `ProductOption` — no brand imagery ships in
  the app.
- **No app icon artwork** is included (see the placeholder note above).
- **Cross-section drag-and-drop in "My Grocery Layout"** uses the classic
  `NSItemProvider`-based `.onDrag`/`.onDrop` (stable since early iOS, no SDK
  surprises) rather than SwiftUI's newer `.draggable`/`.dropDestination` —
  that pair turned out to need a newer iOS than this app targets. Untested on
  a real device as of this writing — the drop target for an empty aisle
  Section is just its header/footer row, which may need a more generous hit
  area once tried on hardware.
- **The Google Maps button builds a plain search-URL deep link** (no API
  key, no cost) — it opens the real Google Maps app/site for reviews and
  photos rather than showing them natively in Home Eats. True in-app Google
  reviews would require a paid Google Places API key.
- **Restaurant search uses Apple's `MKLocalSearch`, not literally Google
  search** — same reasoning as the Maps button: it's free and needs no API
  key, where a real Google Places-backed search would need a paid,
  billed key. Untested on a real device as of this writing.
- **AI-assisted recipe import (ChatGPT/Claude) is not built yet.** A
  consumer ChatGPT Plus/Claude Pro subscription can't be "connected" to a
  third-party app — that access is a separate, usage-billed developer API
  key. The intended design is a Settings field for the user's own
  OpenAI/Anthropic API key, used to reformat a pasted recipe/link into the
  standardized layout while preserving the original source link.
- The project file is generated (`xcodegen generate`) rather than checked
  in, to avoid `.pbxproj` merge conflicts; regenerate it after pulling
  changes that add/remove/move source files.

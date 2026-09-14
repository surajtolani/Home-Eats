import Foundation
import SwiftData

/// Account-backed sync for the signed-in user's personal Restaurant and
/// Recipe libraries — pushes every local row to the backend and pulls down
/// anything the server has that isn't local yet.
///
/// Built directly in response to a real incident: both libraries used to
/// be purely local/on-device (Recipe had a backend copy only for a recipe
/// that had actually been shared; Restaurant had none at all), and a
/// user's entire local store — every local model, both of these included —
/// was wiped by a missing SwiftData migration default (see
/// `HomeEatsApp.swift`'s own doc comment on `ModelContainer` creation for
/// the mechanism, and `GroupSharedGroceryItem.quantityCount`'s for the
/// specific bug). Being account-backed is what makes either library
/// recoverable after a local-store reset, reinstall, or new device instead
/// of gone for good.
///
/// **Deliberately simpler than `GroupSyncService`'s push/pull/reconcile
/// design** — no `GroupSyncState`-style per-row pending-create/-update/
/// -delete state machine, and no attempt at minimal field-level diffing.
/// The reason: a group's shared rows have genuinely competing writers (any
/// member, any time), which is exactly what that state machine exists to
/// protect against; a personal library has exactly one writer — the
/// account it belongs to — so there is no "did someone else already change
/// this since I last synced" question to answer. That lets this be a much
/// blunter, self-healing design:
///
/// - **Push**: every local row with a known backend id gets its FULL
///   current state re-sent (a `PATCH`), every sync pass, whether or not
///   anything actually changed since the last one. A local row with no
///   backend id yet gets created (`POST`) and stamped with the id the
///   response returns. No dirty-tracking, so no call site anywhere in the
///   app needs to remember to flag a row as "needs pushing" after an edit
///   — the next time sync runs (see call sites below), it just re-sends
///   everything's current truth. The cost is bandwidth proportional to
///   library size on every sync tick; judged acceptable at this app's
///   actual scale (a household/friend-group app, not a large catalog — see
///   `RecipeLibraryPayload`'s own doc comment on this same tradeoff
///   elsewhere in this codebase).
/// - **Pull**: only ever ADDS a local row for a backend row with no local
///   match (by backend id) — recovery's entire job. Never overwrites or
///   deletes an existing local row just because the server's copy differs;
///   local is always authoritative once a row exists on this device, so an
///   in-flight local edit can never be clobbered by a pull racing it.
/// - **Delete**: NOT handled here at all — see `RestaurantListView`'s and
///   `RecipesHomeView`'s own delete actions, which call
///   `AccountsAPIClient.deleteRestaurant`/`deleteRecipe` directly, inline,
///   at the moment of deletion (same "immediate, online-only" pattern
///   `GroupSyncService` already uses for adopt/accept — see that file's
///   "Known limitations" note). A delete made while offline doesn't reach
///   the server and the row is orphaned there — an accepted, documented v1
///   gap rather than a second pending-delete state machine, given this
///   whole feature exists to protect against data loss, not against a
///   handful of stray rows a rare offline delete might leave behind.
///
/// Call sites: `RootView` runs this once after the signed-in session is
/// ready (covers app launch and sign-in); `RecipesHomeView`/
/// `RestaurantListView` each also run it from their own `.task`, so
/// visiting either tab opportunistically syncs too. There is no continuous
/// background loop the way group screens have one — this is recovery/
/// durability, not real-time collaboration, so "opportunistic, on the
/// natural points a person would look at this data" is enough.
@MainActor
enum PersonalLibrarySyncService {
    static func sync(modelContext: ModelContext) async {
        await syncRestaurants(modelContext: modelContext)
        await syncRecipes(modelContext: modelContext)
    }

    // MARK: - Restaurants

    private static func syncRestaurants(modelContext: ModelContext) async {
        let localRestaurants = (try? modelContext.fetch(FetchDescriptor<Restaurant>())) ?? []
        for restaurant in localRestaurants {
            do {
                let payload = RestaurantLibraryPayload(restaurant: restaurant)
                if let backendID = restaurant.backendID {
                    _ = try await AccountsAPIClient.updateRestaurant(id: backendID, payload)
                } else {
                    let created = try await AccountsAPIClient.createRestaurant(payload)
                    restaurant.backendID = created.id
                }
            } catch {
                // Best-effort, one row at a time — offline, or a single
                // restaurant's push failing for some other reason,
                // shouldn't block every other row's own push in this same
                // pass. There's no retry queue: the next sync pass (the
                // next relevant screen visit, or the next app launch)
                // simply tries again, since this row's `backendID` is
                // still `nil`/still stale either way.
                continue
            }
        }

        guard let remoteRestaurants = try? await AccountsAPIClient.getMyRestaurants() else { return }
        // Backend ids already represented locally — checked against
        // `localRestaurants` AFTER the push loop above, so a
        // just-created-this-pass row (its `backendID` was just set, in
        // place, on the same object this array already holds — `Restaurant`
        // is a class) is correctly recognized as already-local and never
        // double-inserted.
        let localBackendIDs = Set(localRestaurants.compactMap(\.backendID))
        for remote in remoteRestaurants where !localBackendIDs.contains(remote.id) {
            modelContext.insert(remote.makeLocalRestaurant())
        }
    }

    // MARK: - Recipes

    /// Only `isSavedToCollection` recipes push/pull here — a `.library`
    /// recipe the user hasn't saved yet is browseable built-in content, not
    /// genuinely "theirs" to back up (see `RecipeSource.library`'s own doc
    /// comment); pushing every bundled sample recipe to every account's
    /// backend library the moment they first open the Recipes tab would be
    /// both pointless and a real bandwidth/storage cost at scale.
    private static func syncRecipes(modelContext: ModelContext) async {
        let allRecipes = (try? modelContext.fetch(FetchDescriptor<Recipe>())) ?? []
        let recipesToSync = allRecipes.filter(\.isSavedToCollection)
        for recipe in recipesToSync {
            do {
                if let backendID = recipe.backendRecipeID {
                    let photoBase64: String? = recipe.photoData.map { data in
                        // Same downsize-right-before-upload step as
                        // `RecipeLibraryPayload.init(recipe:)`'s own create
                        // path — see that init's doc comment for why this
                        // re-applies the cap here too rather than trusting
                        // `photoData` as already small enough.
                        (ImageResizing.downsized(data, maxDimension: 800) ?? data).base64EncodedString()
                    }
                    let payload = RecipeLibraryUpdatePayload(
                        title: recipe.title,
                        ingredients: recipe.ingredients.map {
                            RecipeIngredientPayload(name: $0.name, quantity: $0.quantity, unit: $0.unit)
                        },
                        instructions: recipe.instructions,
                        summary: .set(recipe.summary),
                        servings: .set(recipe.servings),
                        prepMinutes: .set(recipe.prepMinutes),
                        cookMinutes: .set(recipe.cookMinutes),
                        photoBase64: .set(photoBase64)
                    )
                    _ = try await AccountsAPIClient.updateRecipe(id: backendID, payload)
                } else {
                    let created = try await AccountsAPIClient.createRecipe(RecipeLibraryPayload(recipe: recipe))
                    recipe.backendRecipeID = created.id
                }
            } catch {
                // Same best-effort, no-retry-queue reasoning as
                // `syncRestaurants` above.
                continue
            }
        }

        guard let remoteRecipes = try? await AccountsAPIClient.getMyRecipes() else { return }
        let localBackendIDs = Set(recipesToSync.compactMap(\.backendRecipeID))
        for remote in remoteRecipes where !localBackendIDs.contains(remote.id) {
            modelContext.insert(remote.makeLocalRecipe())
        }
    }
}

extension RemoteRestaurant {
    /// Builds a local `Restaurant` ready to insert, for a backend row this
    /// device doesn't have a local match for yet — the actual recovery
    /// step: a fresh install, or a local store SwiftData had to reset, has
    /// none of these locally until a pull runs this.
    func makeLocalRestaurant() -> Restaurant {
        Restaurant(
            name: name,
            cuisine: cuisine,
            priceRange: priceRange,
            rating: rating,
            notes: notes,
            websiteURL: websiteUrl,
            address: address,
            isFavorite: isFavorite,
            createdAt: createdAt,
            googlePhotoNames: googlePhotoNames,
            googlePlaceID: googlePlaceId,
            latitude: latitude,
            longitude: longitude,
            backendID: id
        )
    }
}

extension RemoteRecipe {
    /// Same recovery role as `RemoteRestaurant.makeLocalRestaurant()`
    /// above. `.manual` source (not `.shared`, despite the superficial
    /// similarity to `RecipesHomeView.saveSharedRecipe`'s own remote ->
    /// local conversion) — this is the account's OWN recipe being restored,
    /// not one saved from someone else's share, so it should read as an
    /// ordinary recipe with no "Shared" framing anywhere in the UI.
    func makeLocalRecipe() -> Recipe {
        Recipe(
            title: title,
            source: .manual,
            summary: summary,
            instructions: instructions,
            ingredients: ingredients.map { RecipeIngredientEntry(name: $0.name, quantity: $0.quantity, unit: $0.unit) },
            servings: servings ?? 4,
            prepMinutes: prepMinutes ?? 0,
            cookMinutes: cookMinutes ?? 0,
            isSavedToCollection: true,
            photoData: photoData,
            createdAt: createdAt,
            backendRecipeID: id
        )
    }
}

import Foundation

/// A small on-disk JSON snapshot cache for screens that are otherwise
/// "always fetch live, backend is the sole source of truth" — Friends
/// (`FriendsListView`), Groups (`GroupsListView`), and the Shared/Master
/// Library sections of `RecipesHomeView`. See each of those call sites'
/// own doc comments for why they were built with no local SwiftData mirror
/// at all: none of them support offline editing (you can't usefully "add a
/// friend" or "join a group" while offline anyway, since it's a request to
/// a server-side account), so there was never a reason to build the full
/// local-first read/write machinery `PersonalLibrarySyncService`/
/// `GroupSyncService` give Recipe/Restaurant/group plan-and-grocery data.
///
/// The gap this closes is narrower: without ANY local copy, going offline
/// (or just a slow/flaky connection) turned a screen that was showing real
/// data a moment ago into a blank "Something Went Wrong" + Retry state the
/// instant its next live fetch failed — including the very first fetch on
/// a cold launch, before a network request has even had a chance to
/// finish. `LocalDataCache` stores the last successful response's raw JSON
/// keyed by a caller-chosen string (see each call site for its own key,
/// which folds in the signed-in account's id so switching accounts never
/// shows a stale snapshot from a different person), so a screen can show
/// that immediately on appear (stale-while-revalidate: display the cached
/// copy, kick off a live refresh in the background, replace it the moment
/// the refresh succeeds) and fall back to it instead of an error state if
/// a later refresh fails while nothing else is on screen yet.
///
/// Deliberately plain JSON files under Application Support, not a new
/// SwiftData model — this is a read-only cache of wire-format `Codable`
/// structs that already exist (`FriendsList`, `[GroupSummary]`,
/// `[SharedRecipeEntry]`, `[LibraryRecipeEntry]`), not a durable local
/// record anything else in the app reads/writes/relates to, so adding a
/// new `@Model` type (and the schema-migration risk that comes with any
/// new stored SwiftData type — see `HomeEatsApp.swift`'s own doc comment
/// on that risk) would be more machinery than this narrow a job needs.
/// Nothing here is ever written to by a user action, only overwritten
/// wholesale by the next successful live fetch — same "full snapshot, no
/// partial diffing" simplicity `PersonalLibrarySyncService` already leans
/// on, for the same "nothing here has a multi-writer conflict to protect
/// against" reason.
enum LocalDataCache {
    private static func fileURL(key: String) -> URL {
        let directory = URL.applicationSupportDirectory.appending(path: "OfflineCache")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Sanitized so a key that happens to fold in a raw account id
        // (some backend ids/uuids contain characters a path component
        // shouldn't) can never accidentally traverse into a different file
        // than the caller intended.
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
        return directory.appending(path: "\(safeKey).json")
    }

    /// `nil` on literally any failure (file missing, corrupt JSON, a shape
    /// change since the cache was written) — always safe to just fall back
    /// to "nothing cached yet," never worth surfacing as an error of its
    /// own since a live fetch is always about to run right alongside it.
    /// Reuses `AccountsAPIClient.decoder` (its fractional-seconds-aware
    /// ISO-8601 date handling) so a cached snapshot round-trips through
    /// exactly the same rules a fresh live response already does.
    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = try? Data(contentsOf: fileURL(key: key)) else { return nil }
        return try? AccountsAPIClient.decoder.decode(T.self, from: data)
    }

    /// Best-effort — a failed write just means the next successful live
    /// fetch has nothing to fall back on until one succeeds, not worth
    /// surfacing to the person using the app.
    static func save<T: Encodable>(_ value: T, key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: fileURL(key: key), options: .atomic)
    }
}

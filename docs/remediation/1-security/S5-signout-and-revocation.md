# S5 — Sign-out, push unregistration, and token revocation

| | |
|---|---|
| Phase | 1 — Security |
| Severity | Medium |
| Depends on | S0 |
| Size | M |
| Touches | `backend/routes/auth.js` or `backend/routes/me.js`, `HomeEats/Services/AccountSession.swift`, `HomeEats/Services/AccountsAPIClient.swift`, `HomeEats/Services/PushNotificationService.swift`, `HomeEats/Views/Settings/SettingsView.swift` |

## Problem

1. **Pushes keep arriving after sign-out.** `AccountSession.signOut()`
   (`AccountSession.swift:126`) only deletes the local Keychain token. The
   device's APNs token stays registered to that user in `DeviceToken`, so the
   device keeps getting that person's friend request, group invite, and
   recipe share notifications, including other people's names and group
   names, until a different account registers the same token.
2. **No server-side revocation.** `User.tokenVersion` exists and
   `requireAuth` enforces it (`middleware/requireAuth.js`), but **nothing
   ever increments it**. A leaked token stays valid for its full 30 days
   (`signToken` in `routes/auth.js`), and the user can't do anything about
   it.

## Goal

Signing out unregisters this device's push token on the server. Users can
"Sign out of all devices", which invalidates every outstanding token.

## Acceptance criteria

- [ ] `POST /auth/sign-out` (requires auth), body `{ deviceToken?: string }`:
      deletes the `DeviceToken` row matching **both** `token` and
      `userId = req.userId`. Returns 204, including when nothing matched.
- [ ] `POST /auth/sign-out-all` (requires auth): in one transaction,
      increments `User.tokenVersion` and deletes **all** of the user's
      `DeviceToken` rows. Returns 204. Any request with an old token
      afterwards → 401.
- [ ] iOS: an explicit Sign Out calls `POST /auth/sign-out` with the current
      APNs token **before** deleting the Keychain token. It's best-effort: a
      network failure doesn't block sign-out, and the call has a timeout of
      5 s or less.
- [ ] iOS: the automatic sign-out after a 401 does **not** call the server
      (the token is already invalid).
- [ ] iOS: Settings has a "Sign Out of All Devices" button with a
      confirmation dialog that calls `/auth/sign-out-all`, then signs out
      locally.
- [ ] iOS: sign-out does **not** call
      `UIApplication.shared.unregisterForRemoteNotifications()`. Leave
      OS-level registration alone; the next sign-in re-registers the token
      for the new user through the existing `PushNotificationService` path.
- [ ] Integration tests for both endpoints, including "old token → 401 after
      sign-out-all" and "can't delete someone else's device token".

## Steps

### Backend

1. In `routes/auth.js`, the router is mounted **without** `requireAuth`
   (`app.use("/auth", authRouter)`). Add `requireAuth` per route for the two
   new endpoints: `router.post("/sign-out", requireAuth, asyncHandler(...))`.
   Import `requireAuth` from `../middleware/requireAuth`.
2. `/sign-out`: validate `{ deviceToken: z.string().trim().min(1).max(500).optional() }`,
   then `prisma.deviceToken.deleteMany({ where: { token, userId: req.userId } })`.
3. `/sign-out-all`: in `prisma.$transaction`, run
   `user.update({ where: { id: req.userId }, data: { tokenVersion: { increment: 1 } } })`
   and `deviceToken.deleteMany({ where: { userId: req.userId } })`.
4. Document both endpoints in `backend/README.md`.
5. Tests in `test/integration/signOut.test.js`.

### iOS

6. `AccountsAPIClient.swift`: add
   `static func signOut(deviceToken: String?) async throws` and
   `static func signOutAllDevices() async throws`, using `sendNoContent`. For
   `signOut`, set a short timeout. If the shared helpers don't support a
   per-request timeout, add an optional `timeout: TimeInterval?` parameter to
   `sendRaw`.
7. `AccountSession.swift`: split the current `signOut()` into:
   - `func signOut()`: the explicit user action. It's `async` or kicks off a
     `Task`. It awaits `try? await AccountsAPIClient.signOut(deviceToken: PushNotificationService.deviceToken)`,
     then calls `clearLocalSession()`.
   - `func clearLocalSession()`: today's body (delete the Keychain token and
     reset the published fields).
   - Update the 401 path in `AccountsAPIClient` (around line 80 of
     `sendRaw`'s handling, `if http.statusCode == 401`) to call
     `clearLocalSession()`, not `signOut()`.
   - `grep -rn "signOut()" HomeEats` and update every caller. The two in
     `SettingsView.swift` (lines ~112 and ~235) should keep calling the
     user-action version. If it became `async`, wrap with `Task { await ... }`.
   - Make sure `RootView`'s existing reaction to `isSignedIn` flipping (it
     purges local group data) still runs exactly once.
8. `SettingsView.swift`: add a destructive "Sign Out of All Devices" button
   under "Sign Out", with a `.confirmationDialog` explaining "This signs you
   out everywhere, including this phone." On confirm, call
   `AccountsAPIClient.signOutAllDevices()`, then
   `accountSession.clearLocalSession()`. Show an alert on failure and don't
   clear the local session if the server call failed.
9. Push and confirm the `iOS Build` action is green.

## Out of scope

- Shortening token lifetime or adding refresh tokens (consider later; a
  30-day token is acceptable once revocation exists).
- Account deletion (A1 builds on `sign-out-all`'s transaction pattern).

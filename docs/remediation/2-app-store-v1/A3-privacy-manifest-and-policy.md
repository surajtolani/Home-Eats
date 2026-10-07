# A3 — Privacy manifest, privacy policy, in-app links

| | |
|---|---|
| Phase | 2 — App Store 1.0 minimum |
| Severity | **Rejection** (Guidelines 5.1.1 and 5.1.2, App Privacy details, privacy manifest) |
| Depends on | A1 (so the deletion text is true), S6 (logging text) |
| Size | M |
| Touches | `HomeEats/Resources/PrivacyInfo.xcprivacy`, `backend/index.js` (`PRIVACY_POLICY_HTML`, `TERMS_HTML`), `docs/privacy.html`, `HomeEats/Views/Settings/SettingsView.swift`, `HomeEats/Views/Account/AccountSignInView.swift` |

## Problem

1. `PrivacyInfo.xcprivacy` declares **no collected data**
   (`NSPrivacyCollectedDataTypes` is an empty array). The app actually sends
   off the device and stores phone number, first and last name, display
   name, city, state, and country, user content (recipes, plans, grocery
   lists, photos), the social graph (friends and groups), and an APNs token.
   It sends precise latitude and longitude for restaurant search, and recipe
   photos to Anthropic for extraction.
2. The privacy policy (`PRIVACY_POLICY_HTML` in `index.js`) is inaccurate:
   - It says profile fields are optional ("if you choose"), but five are
     required (`computeProfileComplete`, `routes/me.js:27`). A4 changes this,
     so match A4's final state.
   - It claims in-app deletion. That's true after A1.
   - It omits location coordinates, sign-in logs (IP, User-Agent, redacted
     phone; see S6), and retention periods.
   - The contact address is a personal email.
3. There's **no link to the privacy policy inside the app**
   (`grep -rn privacy HomeEats/Views` finds nothing), and sign-in doesn't
   show agreement to the Terms.
4. `docs/privacy.html` exists alongside the server-rendered `/privacy` page.
   Two copies will drift.

## Acceptance criteria

- [ ] `PrivacyInfo.xcprivacy` declares every collected data type in the
      table below, each with `NSPrivacyCollectedDataTypeLinked = true`,
      `NSPrivacyCollectedDataTypeTracking = false`, and purpose
      `NSPrivacyCollectedDataTypePurposeAppFunctionality`.
      `NSPrivacyTracking` stays `false`.
- [ ] The existing UserDefaults required-reason entry is kept. A grep for
      other required-reason APIs (file timestamps, `systemUptime`, disk
      space, active keyboards) is recorded in the PR. Add entries if any are
      found.
- [ ] The privacy policy matches reality: data list, why each item is
      collected, processors (Twilio, Apple, Google, Anthropic, Render),
      retention, deletion path (Settings → Delete Account), contact email,
      and an updated "Last updated" date.
- [ ] One source of truth: `docs/privacy.html` is deleted, or replaced by a
      one-line pointer to `/privacy`. If it's referenced anywhere (GitHub
      Pages?), check before deleting; if it's served, generate it from the
      same string.
- [ ] Settings has a "Legal" section with "Privacy Policy" and "Terms of
      Use" rows that open the backend's `/privacy` and `/terms` in an
      `SFSafariViewController` or SwiftUI `Link`.
- [ ] The sign-in screen shows "By continuing you agree to the Terms of Use
      and Privacy Policy" with both links, above the send-code button.
- [ ] The Terms include an objectionable content and zero-tolerance clause
      (required for user-generated content, Guideline 1.2; coordinate with
      A5).

### Data types to declare

| Manifest key | Why |
|---|---|
| `NSPrivacyCollectedDataTypePhoneNumber` | Account identifier |
| `NSPrivacyCollectedDataTypeName` | First, last, and display name |
| `NSPrivacyCollectedDataTypeCoarseLocation` | City, state, country on the profile; group default location |
| `NSPrivacyCollectedDataTypePreciseLocation` | Latitude and longitude sent with restaurant search. If the server never stores them, you *may* drop this; decide and note it in the PR. The conservative default is to declare it. |
| `NSPrivacyCollectedDataTypeUserID` | Account id |
| `NSPrivacyCollectedDataTypePhotosorVideos` | Recipe photos stored on the server |
| `NSPrivacyCollectedDataTypeContacts` | Friends and groups (social graph), and phone numbers picked from contacts to invite |
| `NSPrivacyCollectedDataTypeOtherUserContent` | Recipes, meal plans, grocery lists, restaurant notes, meal history |
| `NSPrivacyCollectedDataTypeDeviceID` | APNs device token stored server-side (conservative) |

## Steps

1. **Manifest.** Edit `HomeEats/Resources/PrivacyInfo.xcprivacy`. Each entry
   is a dict with the four keys (`NSPrivacyCollectedDataType`, `...Linked`,
   `...Tracking`, `...Purposes` array). Keep the existing XML comment style.
2. **Required-reason scan:**
   `grep -rnE "creationDate|modificationDate|contentModificationDate|systemUptime|mach_absolute_time|volumeAvailableCapacity|activeInputModes|NSFileSystemFreeSize" HomeEats`.
   For each hit, add the matching `NSPrivacyAccessedAPIType` with the right
   reason code, or explain in the PR why it doesn't apply.
3. **Policy.** Rewrite `PRIVACY_POLICY_HTML`. Required sections: Information
   We Collect (match the table above, plus sign-in logs), How We Use It,
   Sharing and Processors, SMS (keep the existing A2P wording, which is
   registered with carriers), Retention (account data until deletion; logs
   for N days per Render's retention, confirm with a human; backups for N
   days), Deletion, Children (not directed to under-13s), Changes, Contact.
   Use the placeholder `privacy@<domain>` for contact and leave a
   **[HUMAN]** note to confirm the real address.
4. **Terms.** Add to `TERMS_HTML` a "User Content and Conduct" section:
   no objectionable, abusive, or illegal content; zero tolerance; content may
   be removed and users banned; how to report (in-app Report button); blocked
   users.
5. **iOS links.** Add `static let privacyPolicyURL` and `termsURL` in one
   place. Use `AccountsAPIClient`'s base URL plus `/privacy` and `/terms` so
   R2's environment switch covers them. Add the Settings "Legal" section and
   the sign-in consent line (`AccountSignInView.swift`). Use
   `SwiftUI.Section`.
6. **Remove** `docs/privacy.html` (after checking references with
   `grep -rn "privacy.html" .`).
7. Push and confirm the `iOS Build` action is green.

## [HUMAN] steps

- App Store Connect → App Privacy: answer the questionnaire to match the
  manifest table exactly. Data is linked to the user, not used for tracking,
  and used for App Functionality.
- Set a role-based contact email (not personal) and put it in the policy.
- App Store Connect → Privacy Policy URL:
  `https://<backend-host>/privacy`.

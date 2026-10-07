# A8 — Build and config hygiene for submission

| | |
|---|---|
| Phase | 2 — App Store 1.0 minimum |
| Severity | Rejection risk (ATS justification, SDK requirement) and correctness |
| Depends on | — |
| Size | S |
| Touches | `HomeEats/Supporting/Info.plist`, `project.yml`, `.github/workflows/ios-build.yml`, `README.md` |

## Problem

1. **Stale ATS exception.** The checked-in `HomeEats/Supporting/Info.plist`
   still has `NSAllowsArbitraryLoads: true`, while `project.yml` deliberately
   removed it and explains why. XcodeGen should regenerate the plist from
   `project.yml`, but a stale copy in git is a trap: anyone building another
   way, or a future XcodeGen behavior change, ships a blanket ATS exception
   that reviewers question.
2. **CI uses an older toolchain than submission.** `ios-build.yml:41` runs
   on `macos-14`, which can't run the current Xcode. App Store uploads
   require building with a recent SDK (currently Xcode 26 / iOS 26 SDK).
   CI passing doesn't prove the submission build compiles.
3. **Version.** `MARKETING_VERSION: "0.1.0"` should be `1.0.0` for the App
   Store release.
4. **README is out of date.** It says "local-first, no account required",
   but sign-in is now mandatory. It also says "AI-assisted recipe import …
   is not built yet", but it has been built, plus other stale claims.
5. **Plain-HTTP Apple Maps link.** `GroupRestaurantPreviewView.swift:129`
   builds `http://maps.apple.com/...`. iOS hands `maps.apple.com` links to
   Maps, but use `https` to be consistent and ATS-safe.

## Acceptance criteria

- [ ] `Info.plist` has no `NSAppTransportSecurity` key, and every other key
      matches `project.yml`'s `info.properties` exactly. Add a CI step that
      runs `xcodegen generate` and then `git diff --exit-code HomeEats/Supporting/Info.plist`,
      so drift fails the build.
- [ ] CI runs on `macos-15` (or the newest runner image that has Xcode 26),
      and selects the newest available Xcode as it does today. The job prints
      `xcodebuild -version`. If no hosted runner has the required Xcode yet,
      leave `macos-14` and add a **[HUMAN]** note in the PR to archive
      locally with Xcode 26.
- [ ] `MARKETING_VERSION: "1.0.0"`. `CURRENT_PROJECT_VERSION` must be higher
      than the last uploaded build (20 at time of writing), so bump it.
- [ ] `http://maps.apple.com` becomes `https://maps.apple.com`.
- [ ] The README's opening paragraph and "Known limitations" are corrected:
      an account is required, the backend exists, AI import is built, and
      the app icon exists. Keep edits factual and short. Point to
      `docs/remediation/` for the open items.

## Steps

1. Edit `Info.plist`. Remove the ATS dict, and check `UIRequiresFullScreen`
   against A6 (if A6 landed, it should already be gone).
2. Edit `.github/workflows/ios-build.yml`: change the runner and add the
   drift check step after "Generate Xcode project".
3. Edit `project.yml` versions.
4. Fix the maps URL.
5. Edit `README.md`.
6. Push and confirm the `iOS Build` action is green on the new runner.

## [HUMAN] steps

- Archive and upload with Xcode 26. In App Store Connect, confirm the build
  reports the current SDK.
- The `aps-environment` entitlement is `development` in
  `HomeEats.entitlements`. Xcode rewrites this to `production` when exporting
  for App Store or TestFlight. Check this by confirming push works on a
  TestFlight build with `APNS_PRODUCTION=true` on the server.

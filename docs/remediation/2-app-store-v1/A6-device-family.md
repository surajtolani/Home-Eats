# A6 — Ship 1.0 as iPhone-only

| | |
|---|---|
| Phase | 2 — App Store 1.0 minimum |
| Severity | Rejection risk (Guideline 2.4.1: iPhone apps should run on iPad; 4.0 design; iPad screenshots required) |
| Depends on | — |
| Size | XS |
| Touches | `project.yml`, `HomeEats/Supporting/Info.plist` |

## Problem

`project.yml:21` sets `TARGETED_DEVICE_FAMILY: "1,2"` (iPhone and iPad), but
the comment there admits there's no iPad layout. The app is portrait-only
and relies on `UIRequiresFullScreen`, which recent iOS SDKs deprecate and
ignore for apps that support iPad. Declaring iPad support means:
- App Review tests on iPad, where layout issues lead to a 4.0 or 2.1
  rejection;
- App Store Connect requires iPad screenshots.

An iPhone-only app still runs on iPad in compatibility mode, which Apple
reviews as an iPhone app.

## Acceptance criteria

- [ ] `TARGETED_DEVICE_FAMILY: "1"` in `project.yml`, with the comment
      rewritten to say: iPhone-only for 1.0, and a native iPad layout is
      future work.
- [ ] `UIRequiresFullScreen` removed from `project.yml` `info.properties`
      and from `HomeEats/Supporting/Info.plist`. It only mattered for iPad
      multitasking, and is meaningless on iPhone-only. Remove the comment
      that justifies it too.
- [ ] `iOS Build` action is green.

## Steps

1. Edit `project.yml` (the `settings.base` block and `targets.HomeEats.info.properties`).
2. Edit `HomeEats/Supporting/Info.plist` to match. XcodeGen regenerates it,
   but keep the checked-in copy in sync (see A8).
3. Push and check CI.

## [HUMAN] steps

- **Important:** if any build that supports iPad has been **released on the
  App Store** (not just TestFlight), you can't remove iPad support from later
  versions. Check App Store Connect first. TestFlight-only builds are fine.
- Upload iPhone screenshots only (6.9" and 6.5" sets).

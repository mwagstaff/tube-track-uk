# TubeTrack UK 1.0 — App Store preparation

Prepared 15 September 2026. App Store Connect app ID: 6808680996.

[Open version 1.0 draft](https://appstoreconnect.apple.com/apps/6808680996/distribution/ios/version/inflight)

## Completed

- Uploaded and ordered ten screenshots under English (U.K.), iPhone 6.9-inch. App Store Connect confirms 10 of 10 and uses them for the 6.5-inch slot.
- Saved promotional text, description, keywords, marketing URL, copyright and review notes.
- Disabled “Sign-in required”, since app sign-in is not required.
- Saved subtitle “Live London rail maps & status”, primary category Navigation, secondary category Travel.
- Built the current Release app for Simulator and created `TubeTrackUK.xcarchive` for iOS, version 1.0, build 1.
- Ran all 411 tests and separately repeated the failing share-sheet test.
- Left the version in Prepare for Submission; no review submission or publication was performed.

## Screenshots

Original native captures are in `screenshots/all/`. App Store files are in `screenshots/upload/`. The contact sheet is `screenshots/contact-sheet.jpg`.

All screenshots show the actual Release app on an iPhone 17 Pro Max simulator running iOS 26.5, with live data captured on 15 September 2026. Near Me uses the simulated central-London location 51.5074, -0.1278, rather than a personal location. Status-bar time is 09:41.

The 1320 × 2868 PNG originals contain alpha. Uploaded JPEG copies preserve the original dimensions and remove alpha, as required by [Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

### Uploaded order

1. Network detail around Charing Cross
2. Geographic map detail
3. Expanded disruptions lozenge
4. Full network overview
5. Geographic map overview
6. All mobile coverage, with explanatory toast
7. Underground mobile coverage, with explanatory toast
8. Live trains on geographic map, with explanatory toast
9. Near Me, with departures
10. Works, with Saturday selected

Additional originals include the all-lines toast, all/major/minor disruption-filter toasts, live train line controls, and today's Works screen. The file named `13-map-train-line-filter.png` shows the available line controls; it does not demonstrate a confirmed single-line selection.

## Validation

Release simulator build: **passed**.

iOS archive: **passed**. Export for App Store Connect: **blocked**, with `No Accounts` and no App Store provisioning profile for `dev.skynolimit.TubeTrackUK`. Xcode Settings → Apple Accounts was opened and confirms no account is signed in. Signing into Chrome does not sign into Xcode. No IPA was exported and no build was uploaded.

Full test suite: **409 passed, 2 failed**.

- `BeckMapRepositoryTests/fullUndergroundLabelsHaveProgressiveVisibilityTiers()`: expects 66 network-tier labels; current result is 67.
- `TubeGameShareButtonTests/tapPresentsImageShareSheetFromPausedGameAndCanReopen()`: expected a presented `UIActivityViewController`, received nil. This also failed when rerun on its own with parallel testing disabled.

These failures remain unresolved. The test failure alone does not establish whether users encounter a share-sheet failure in the Release app.

Existing build warnings include actor-isolation warnings in `AppTypography.swift`. No application source was changed in this preparation. The pre-existing edit to `RootTabView.swift` was included in the builds and left intact.

Machine-readable results are in `validation/tests-summary.json` and `validation/share-retest-summary.json`. Detailed test bundles and build logs are retained locally.

## Outstanding before submission

- Sign into the appropriate Apple Developer account in Xcode, export/upload the archive, complete build processing/export compliance and attach the build to version 1.0.
- Investigate the two failing tests and validate any fixes before replacing this archive.
- Supply the Support URL, Privacy Policy URL and review contact name, email and phone number. No contact details were inferred or submitted.
- Complete App Privacy disclosures after confirming app, backend and optional Game Center data handling. The privacy questionnaire has not been started.
- Complete Content Rights and Age Ratings. These remain unset in App Store Connect.
- Choose a price and countries/regions. Neither is configured.
- Confirm the desired release timing. The existing automatic-release-after-approval setting was left unchanged.

`ExportOptions.plist` is prepared for an App Store Connect export using automatic signing and team SJ8X4DLAN9. The archive has not been submitted for review.

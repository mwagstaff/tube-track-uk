# TubeTrack UK 1.2 — App Store release candidate

Prepared 26 September 2026 for App Store app ID 6808680996. The 1.2 (1) build
was uploaded to Apple and selected in the 1.2 App Store Connect draft. It has
not been submitted for review. The source working tree contains other
uncommitted changes, so record a reviewed commit before treating this binary
as the final release.

## Binary and validation

- `export/TubeTrackUK.ipa` is the App Store export of version 1.2, build 1.
  SHA-256: `31b6c2f37b4fcc79e1044763e622e11e4b4337993454055b4b3943256d3abc19`.
- Xcode 27.0 archived and exported with the valid Apple Distribution identity
  for team `SJ8X4DLAN9`. The iOS app, iOS widget, Watch app and Watch widget
  use App Store provisioning profiles, version 1.2, build 1. The exported iOS
  app has `aps-environment=production` and `get-task-allow=false`.
- The exported IPA passes `codesign --verify --deep --strict`. Its embedded
  Watch app contains a compiled 1024 px `AppIcon`; its Info.plist has both
  `CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconFiles` and
  `CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName` set to `AppIcon`.
- The full iPhone 17 Pro Max (iOS 26.5) simulator suite passed with no failures.
  See `validation/ios-tests-summary.json`. The API suite passed 210 tests.
- The Watch app built and launched on an Apple Watch Series 11 (46 mm)
  simulator. The Watch gallery contains line status, widget line selection,
  an actual Watch face showing the new line status widgets, and the All other
  lines screen. All four upload copies are 416 × 496 and alpha-free. The Watch
  face and All other lines originals were captured on an Apple Watch Ultra 2
  at 410 × 502; their upload copies were fitted to 416 × 496 with black padding
  and no cropping or distortion.
- The 1.2 draft has seven new 1320 × 2868 iPhone screenshots, with the map,
  River Bus, and Cable Car first, and four Watch screenshots. The Watch face
  widget capture leads the Watch gallery.
  The app description, What's New text, and App Review notes were updated to
  describe the new features. The previous 1.1 screenshot set was replaced.
- Read-only checks of the production status, River Bus network and boats, and
  Cable Car network, status and hours endpoints returned HTTP 200.

Xcode 27 still reports actor-isolation warnings in `AppTypography.swift`. They
did not prevent the archive, export or tests.

The signed Xcode archive and test result bundle are retained on this Mac at
`/tmp/TubeTrackUK-1.2-signed.xcarchive` and
`/tmp/TubeTrackUK-1.2-release-tests.xcresult`. The IPA and export summary are
also retained here in `export/`.

## Before App Review

1. Review the App Privacy answers and privacy policy. Version 1.2 sends a
   random installation ID and app-open/feature-open events to the first-party
   API. The server retains salted, daily installation hashes for 45 days. The
   App Store privacy answers must cover the iPhone, widgets and Watch app.
2. Confirm the production API has the `POST /api/v1/usage` handler before
   release. A read-only `GET` returns 404 and does not establish whether the
   POST route is deployed. Verify the other new endpoints and push service on
   the release environment.
3. Check the privacy policy URL, age rating, content rights, availability and
   release timing in App Store Connect. The draft is set to release
   automatically after approval; confirm that this is the intended release
   choice before adding it for review.
4. On devices, verify Watch line selection and complications, Game Center score
   sharing, location permission, offline behavior, Live Activity push and
   the production API. The share-button unit test verifies activity-controller
   creation, while an actual system share sheet needs device verification.

Suggested What's New text:

> Explore River Bus piers and the Cable Car on both maps, with departures and
> service information. On Apple Watch, see the status of your chosen rail
> lines and add line status widgets to your Watch face. This update also
> improves map responsiveness and makes live update times clearer.

Apple's current [watchOS metadata guidance](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-watchos-app-information/)
calls for Watch screenshots and a description of Watch functionality. Its
[screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
accept 416 × 496 Series 11 captures without alpha. Review
[App Privacy guidance](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
before submitting.

## Preparing future Watch screenshots

Run the shared `mac-tooling` script with a capture path. It creates a
`-app-store-416x496.jpg` next to the original unless an output path is given:

```bash
~/dev/mac-tooling/app-store/prepare-watch-screenshot.sh "/path/to/Watch screenshot.png"
```

The script requires ImageMagick (`brew install imagemagick`). It flattens
transparency onto black, fits the entire capture without cropping or stretching,
adds black padding as needed, removes metadata, and checks that the JPEG is
exactly 416 × 496 before printing its path.
The sibling `prepare-iphone-screenshot.sh` script produces 1320 × 2868 JPEGs
for the 6.9-inch iPhone gallery.

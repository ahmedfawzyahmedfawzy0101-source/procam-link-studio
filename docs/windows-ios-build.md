# Windows to iPhone Build Pipeline

This project is designed so you can develop on Windows, push to GitHub, let GitHub Actions build on macOS, download an IPA, then use Sideloadly on Windows to sign and install it on your own iPhone.

Current strategy: do not build or install intermediate IPAs. Use CI compile checks during development and run the IPA workflow only for the final v1.0 release gate.

## What Gets Built

- App: `ProCamLinkStudio`
- Default bundle identifier: `com.procamlink.studio`
- Workflow output: `ProCamLinkStudio.ipa`
- Signing model: unsigned app package intended for local Sideloadly signing

The bundle identifier is configurable through the Xcode build setting `PROCAM_BUNDLE_IDENTIFIER`. The manual IPA workflow exposes this as a `bundle_identifier` input.

## Why the IPA Is Unsigned

Xcode's normal `archive` plus `-exportArchive` distribution path requires valid Apple signing assets and a provisioning profile for iOS app installation. Those credentials must not be committed to source control.

For Sideloadly, the most compatible source-controlled workflow is:

```text
xcodebuild unsigned iphoneos .app
  -> Payload/ProCamLinkStudio.app
  -> zip Payload
  -> ProCamLinkStudio.ipa
  -> Sideloadly signs locally with your Apple ID
```

This IPA is not App Store, TestFlight, Ad Hoc, or Enterprise signed. It is a generic unsigned IPA container that Sideloadly can re-sign during installation.

## GitHub Actions Workflows

### CI Compile Check

File: `.github/workflows/ios-ci.yml`

Runs on every push and pull request. It uses a GitHub-hosted `macos-26` runner and the runner's installed default stable Xcode. It compiles the app for iOS Simulator with signing disabled, which is the fastest way to catch Swift and Xcode project errors without requiring certificates.

### IPA Build

File: `.github/workflows/ios-ipa.yml`

Runs only when manually triggered from GitHub Actions. It builds a Release device `.app` for `iphoneos` with signing disabled, packages it as `Payload/ProCamLinkStudio.app`, and uploads `ProCamLinkStudio.ipa` as an artifact.

## Step-by-Step

1. Develop on Windows in this repository.
2. Commit your changes.
3. Push to GitHub.
4. Open the repository on GitHub.
5. Go to `Actions`.
6. Confirm `CI Compile Check` passes after the push.
7. Select `IPA Build`.
8. Click `Run workflow`.
9. Optionally change `bundle_identifier`; leave it as `com.procamlink.studio` unless you need a different app identity.
10. Wait for the workflow to finish.
11. Open the completed workflow run.
12. Download the `ProCamLinkStudio-unsigned-ipa` artifact.
13. Extract the downloaded artifact zip on Windows.
14. Open Sideloadly.
15. Connect your iPhone over USB.
16. Select `ProCamLinkStudio.ipa`.
17. Enter your Apple ID in Sideloadly when prompted.
18. Start installation.
19. On iPhone, trust the developer profile if iOS asks for it.
20. Launch `ProCamLinkStudio`.
21. Grant camera permission.
22. Verify the live preview and camera switching.
23. On Windows, open OBS and add a Media Source for an SRT listener endpoint such as `srt://:9000?mode=listener`.
24. In the iPhone app Stream panel, set caller mode, enter the Windows LAN IP and matching port, then start SRT.
25. Confirm OBS receives video and audio.
26. Record test results: iPhone model, iOS version, cameras shown, preview status, rotation behavior, SRT endpoint, OBS video/audio status, reconnect behavior, and any crash or permission issue.

## Privacy Strings Preserved

The app declares:

- `NSCameraUsageDescription`
- `NSMicrophoneUsageDescription`
- `NSLocalNetworkUsageDescription`

## If Signed IPA Export Is Needed Later

Do not put Apple ID credentials, `.p12` certificates, passwords, provisioning profiles, or App Store Connect keys directly into source control.

If a future workflow needs Xcode's official signed IPA export, GitHub Actions secrets would typically include:

- `APPLE_TEAM_ID`
- `IOS_CERTIFICATE_P12_BASE64`
- `IOS_CERTIFICATE_PASSWORD`
- `IOS_PROVISIONING_PROFILE_BASE64`
- Optional App Store Connect API values for automated distribution:
  - `APP_STORE_CONNECT_KEY_ID`
  - `APP_STORE_CONNECT_ISSUER_ID`
  - `APP_STORE_CONNECT_PRIVATE_KEY`

That signed-export path is intentionally not enabled now because the current goal is Sideloadly re-signing from Windows.

## Current Phase Boundary

This setup does not start Phase 2. It only makes the Phase 1 iOS project buildable through GitHub Actions and packages an installable IPA container for Sideloadly.

# Desktop Pilot

Desktop Pilot is a native macOS menu-bar assistant. You type a task. The app reads the selected window on this Mac, asks TypeSafe's Jev model which of the real controls to use next, and performs one action at a time.

Screen images stay on this Mac. Jev receives text only: your task, labels from the selected window, and a short history of actions. See [Privacy](docs/PRIVACY.md).

## Requirements

- macOS 14.2 or later. Apple Silicon is the tested target.
- Xcode 16 or later (developed with Xcode 26.6).
- A TypeSafe API key from [typesafe.ai](https://www.typesafe.ai).

## Open and run

1. Open `DesktopPilot.xcodeproj` in Xcode.
2. Select the DesktopPilot scheme. For day-to-day use, set Signing to your Apple Development team. The project defaults to Sign to Run Locally so it builds without a team. A local signature changes whenever the binary changes, and macOS will ask for Accessibility again after those rebuilds. A stable development signature avoids that.
3. Build and run from Xcode. Do not expect a Dock icon. The app lives in the menu bar (scope icon).
4. On first launch, grant Accessibility and Screen Recording. Accessibility is required to read controls and to click or type. Screen Recording is used only to recognize text in the selected window when Accessibility labels are sparse. Neither permission records video.
5. Open Settings and save a TypeSafe API key. It is stored in Keychain and is not written to logs.
6. The default model is `jev-latest`. Review actions is the default mode: every proposed action is highlighted and waits for Approve.

Show the panel with Control-Shift-D. Stop a running task with Control-Option-Escape, or the Stop button. Both shortcuts can be changed in Settings.

## Demo fixture

The DemoFixture scheme is a small window with navigation, two Open buttons, a nested More menu, a dialog, a disabled control, a note field, a layout toggle, and a "Status: Complete" line. Use it to try tasks without touching a real account. Example: "Open my saved songs." with Demo Fixture focused, then start the task from Desktop Pilot.

## Checks that do not launch the app

```sh
swift test --package-path Packages/PilotCore
```

Live calls to `api.typesafe.ai` are skipped unless `TYPESAFE_API_KEY` is set in the environment. They are separate from the mocked tests.

```sh
xcodebuild -project DesktopPilot.xcodeproj -scheme DesktopPilot -configuration Debug -destination 'platform=macOS' build CODE_SIGN_IDENTITY=-
xcodebuild -project DesktopPilot.xcodeproj -scheme DemoFixture -configuration Debug -destination 'platform=macOS' build CODE_SIGN_IDENTITY=-
```

`scripts/build-release.sh` builds the Release app and writes `build/DesktopPilot.dmg`. It does not launch anything.

## More

- [Architecture](docs/ARCHITECTURE.md)
- [Privacy and limitations](docs/PRIVACY.md)
- [Tests](docs/TESTING.md)
- [Manual acceptance](docs/ACCEPTANCE.md)
- [Release, signing, notarization](docs/RELEASE.md)

# Release

## Local package

```sh
chmod +x scripts/build-release.sh
scripts/build-release.sh
```

The script builds the Release configuration of Desktop Pilot with an ad-hoc signature (`CODE_SIGN_IDENTITY=-`), writes `build/DesktopPilot.dmg`, and archives to `build/DesktopPilot.xcarchive`. It does not launch the app, notarize it, or upload it.

The default Xcode project uses Sign to Run Locally for the same reason: this repository does not assume a signing team. An Apple Development identity is available on the machine this was written on, and it is intentionally not embedded.

## Signing for daily use

1. Open the project in Xcode.
2. Select the DesktopPilot target, Signing & Capabilities.
3. Choose your team and set the signing certificate to Apple Development.
4. Leave the App Sandbox off. Accessibility, global shortcuts, and Quartz events are unreliable inside the sandbox, and this app is not sandboxed on purpose.

Rebuild from Xcode after that so macOS can remember the Accessibility grant across builds.

## Notarization

After you have a Developer ID Application certificate:

1. Archive the DesktopPilot scheme in Xcode with that certificate and Hardened Runtime enabled.
2. Notarize with `notarytool`, staple the ticket, then put the stapled app in a DMG.

This repository does not run those steps. Do not ship the ad-hoc DMG outside your own Mac. Gatekeeper will reject it on other machines.

No service is purchased and nothing is published from this project.

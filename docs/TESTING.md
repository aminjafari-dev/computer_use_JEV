# Tests

## Mocked package tests

Run from the repository root:

```sh
swift test --package-path Packages/PilotCore
```

These tests do not call the network and do not launch either app. They use a scripted observer, executor, and decision source.

Covered:

- Coordinate conversion for the primary display, a display left of the primary, and a Retina Vision box.
- Merging overlapping Accessibility and OCR observations without dropping distinct controls, and dropping secure fields.
- Distinct ids for duplicate labels, exclusion of disabled and secure controls, text insertion only when the user supplied text, and the 120-candidate cap.
- Request JSON allowlist: no screenshot, no secure value, no user-supplied text.
- Rejection of invented choice ids, probability sums that are not 1, and out-of-range Noul values.
- The documented Choice confidence formula, low-confidence and ambiguous review, and consequential-action review.
- Stale and cross-application targets.
- Completion phrases versus an unchanged screen.
- Repeated screens and ineffective actions.
- Rate-limit retry with `retry-after`, no retry on 401, and bounded network retries. The API key is absent from log lines.
- Task runner: approved click ending in a completion phrase, cancellation during approval, ineffective actions, repeated state, persistent stale targets, consequential review in Automatic mode, exact text insertion, permission loss, repeated API failure, and an unverified stop at the action budget.

Result on this machine (macOS 26.6, Swift 6.3):

```
Executed 35 tests, with 1 test skipped and 0 failures.
```

The skipped test is `LiveJevTests.testLiveChoiceRoundTrip`. It runs only when `TYPESAFE_API_KEY` is set, and it was not run. A green mocked suite is not a live API test.

## App builds

Debug builds of DesktopPilot and DemoFixture succeeded with `xcodebuild` and `CODE_SIGN_IDENTITY=-`. The Release build succeeded the same way and `scripts/build-release.sh` wrote `build/DesktopPilot.dmg`. The apps were not launched. Accessibility, Screen Recording, clicking, OCR, and the live Jev call were not exercised from here.

See [ACCEPTANCE.md](ACCEPTANCE.md) for the manual pass.

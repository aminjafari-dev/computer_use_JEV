# Architecture

Desktop Pilot splits decisions that can be tested without macOS UI from the AppKit, Accessibility, Vision, and ScreenCaptureKit bindings.

## PilotCore

`Packages/PilotCore` has no AppKit dependency.

- `CoordinateConverter` maps Cocoa's bottom-left screen space, Vision's normalized bottom-left boxes, and capture pixels into one shared space: global points, origin at the top-left of the primary display, y downward. Accessibility frames and Quartz events already use that space.
- `ObservationMerger` collapses overlapping observations and records every source. Accessibility geometry wins over Core ML, which wins over OCR. Secure fields are dropped.
- `CandidateBuilder` emits only operations the executor implements: click, double-click, right-click, a short scroll, an allowlisted key, or insertion of text the user supplied. Disabled and secure controls are described as unavailable, not executable. The set is capped at 120 so the Choice question stays under the API's 255-option limit. When nothing in the task matches a label, the builder keeps the first 40 controls in reading order instead of sending the whole tree.
- `JevRequestSerializer` builds `POST /v1/systemone` with an allowlisted state. One request asks three questions: `next_action` (Choice, including `none_blocked`), `task_complete` (Noul), and `blocked` (Noul).
- `JevClient` retries 429, 529, timeouts, and network failures with backoff, and honors `retry-after` under 30 seconds. It does not retry 401 or 422. Every body is validated before a candidate can be used. Unknown ids, bad probability sums, and out-of-range values are rejected.
- `DecisionEngine` turns a validated answer into review reasons. Confidence below 0.5, or a winner less than twice as likely as the runner-up, requires review. Those defaults follow TypeSafe's documented confidence statistic and a local ambiguity check. They are settings, not measured accuracy.
- `SafetyPolicy` forces review for send, pay, delete, share, permission, credential, install, and shell wording, matched on whole words. The model cannot add to this list.
- `TaskRunner` loops observe, build, decide, review, revalidate, execute, verify. It stops on cancellation, permission loss, repeated screens, ineffective actions, stale targets, API failures, and action or time budgets.
- `ResultVerifier` treats a new on-screen completion phrase as evidence. A click that does not change the screen is not completion. Exhausting the budget without that evidence is `unverified`.

## App

- `PermissionManager` checks Accessibility and Screen Recording, explains them, opens the relevant settings, and refreshes when the app becomes active.
- `AXScreenObserver` walks the focused window of the pinned app, never this app's own windows. If labels are sparse and Screen Recording is allowed, it captures that window with `SCContentFilter(desktopIndependentWindow:)` and runs Vision OCR. A bundled `UIDetector.mlmodelc` is optional. If it is missing or does not produce `VNRecognizedObjectObservation` results, detection stays empty. Nothing is fabricated.
- `AXActionExecutor` prefers `AXPress` or `AXShowMenu`, then a Quartz click. Text is the user's exact string, written with `AXValue` or Unicode events, never the clipboard. Secure fields are refused. Keys are Escape, Return, Tab, arrows, and Page Up/Down.
- The command panel and highlight overlay use `sharingType = .none`, and the overlay ignores mouse events. Highlight frames are converted back to Cocoa coordinates.
- The task runs in a detached task so capture and networking are not tied to the main actor. Cancellation is cooperative through `Task.checkCancellation`, the run control, and the approval wait.

Jev cannot invent a target id, a coordinate, or text. The executor only runs a candidate id that was in the request, after the control is found again.

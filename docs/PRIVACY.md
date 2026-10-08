# Privacy and limitations

Screen images are processed locally. Relevant screen text, your task, and recent actions are sent to TypeSafe to choose the next action.

The app is not fully offline. Choosing an action needs the TypeSafe API.

## What stays on this Mac

- Screenshots and window captures. Saving them is off until you turn on "Save window captures on this Mac" in Settings. They are written under Application Support and are not uploaded.
- The API key, in the login Keychain.
- The optional text you type into "Text to enter". Jev is told only that text is available, not what it says.

## What is sent

The request serializer allows these state fields only: the task, whether you supplied text, the app name, the window title, a fixed notice that screen text is untrusted, short labels and roles for executable controls, labels of unavailable controls, and up to six recent actions with whether the screen changed. Secure fields are omitted. The clipboard is never read for this.

Screen text is untrusted. It cannot change the task, grant a permission, or widen the action allowlist. Consequential controls (send, pay, delete, share, permissions, credentials, install, shell) always wait for approval, including in Automatic mode. That check is in app code.

Diagnostic export is a file you save yourself. It contains the task result and step labels. It does not contain the API key. Logs redact a stored key and Bearer tokens if one is ever passed into a message. The client does not log the key.

## Limitations

- The first release does not run shell commands or open downloaded programs.
- Jev sees text, not pixels. Controls without an Accessibility label or recognized text can be missed. A Core ML detector is a plug-in, not a bundled model. No model was trained for this app.
- Completion is `unverified` when the action or time budget ends without a visible completion phrase such as "Status: Complete". A successful click is not treated as success by itself.
- The assistant acts on the app that was focused when the task started, not on every window on the desktop.
- Menus, dialogs, and moving windows are handled by reading Accessibility again before each click. If the control is gone twice, the task stops.
- English is Jev's strongest language. Other languages are accepted by the API with lower expected accuracy.
- Live behavior depends on Accessibility permission, Screen Recording, and the frontmost app. Those paths are not covered by the unit tests.

# Manual acceptance

These workflows were not run in this environment. The app was not launched. Check them in Xcode against Demo Fixture unless a step says otherwise. Record pass or fail beside each item.

1. First launch with missing permissions. A new user, or after resetting the permission, sees why Accessibility and Screen Recording are needed and can open the settings panes. The task does not start without Accessibility.
2. Invalid API key. Saving a bad key and starting a task ends with a message to check Settings, not a stack trace. The key does not appear in Console logs.
3. A simple approved click. Focus Demo Fixture, task "Open Home", Review actions. The Home control is highlighted. Nothing is clicked until Approve.
4. A multi-step task in Demo Fixture. "Open my saved songs." reaches the Songs Open button and can end when the window shows "Status: Complete".
5. Exact text. Put `Exact words` in Text to enter and ask to save the note. The field contains that string and not text the model invented.
6. An absent or ambiguous target. Ask for a control that is not in the window. The task stops without clicking a lookalike, or it asks you to approve because the choice was close.
7. No useful change. Approve an action that leaves the same screen. The task stops after the ineffective-action limit.
8. Emergency stop. Start a task and press Control-Option-Escape (or your stop shortcut). The highlight goes away and the result says you stopped it.
9. Window movement or app change. Move the Demo Fixture window, or switch to another app, during review. The click is not delivered to a stale location.
10. Network failure. Turn off the network, or use a revoked key, and confirm the task stops with a retry or settings hint after repeated failures.
11. Unverified completion. Set a small action limit and use a task whose screen never shows "Status: Complete". The outcome is unverified, not completed.

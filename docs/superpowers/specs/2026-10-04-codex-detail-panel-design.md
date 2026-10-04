# Codex conversation detail panel

Approved design: a rounded panel directly below the notch with matching left and right edges, no popover arrow. Header contains title and status. Scrollable conversation above a fixed composer and send button. Send targets the selected task ID, clears only on success and preserves text on failure.

Use a key-capable nonactivating child NSPanel anchored to the main layout. Subscribe to task updates, dismiss when selection clears or page closes, reuse existing XPC sender. No automatic test messages, commits or pushes.

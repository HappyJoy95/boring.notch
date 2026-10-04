# Codex Detail Panel Implementation Plan

> Execute inline using executing-plans; preserve existing uncommitted changes.

**Goal:** Implement the approved aligned conversation panel with direct sending.

**Architecture:** Attach an AppKit anchor to ContentView and host the detail in a key-capable child NSPanel. Observe the task service for live updates.

**Tech Stack:** SwiftUI, AppKit, existing XPC sender.

- [x] Remove card popover and reply sheet in NotchHomeView.swift; integrate fixed composer with disabled empty/send-in-flight states and retained errors.
- [x] Add anchor and child panel in the same file, aligned using screen coordinates, capped to available screen height, cleaned up on dismissal.
- [x] Attach anchor to the full main-layout frame in ContentView.swift.
- [x] Run git diff --check and unsigned Debug xcodebuild; inspect task ID capture and success/failure handling.
- [x] Report build evidence and remaining runtime validation without sending test messages or committing.

Verification: unsigned Debug xcodebuild exited 0 with BUILD SUCCEEDED; git diff --check passed. Runtime geometry, keyboard interaction and real IPC delivery remain unverified. No messages sent.

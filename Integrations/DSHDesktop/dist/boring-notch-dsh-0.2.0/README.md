# Boring Notch DSH bridge

Version 0.2.0. This is a portable, read-only plugin bundle; it contains no machine-specific paths, credentials, or dependencies.

This DSH plugin exposes a read-only local bridge for Boring Notch. It uses DSH's `sessionController.list()` and `sessionController.page()` APIs; it does not read session log files, activate agents, send prompts, or stop sessions.

The plugin follows DSH's public `workspaceController.follow()` stream for the authoritative `pinnedSessionIds` set. It serves only on `127.0.0.1`, requires a random bearer token, and writes that token to `~/Library/Application Support/Boring Notch/DSH/bridge-config.json` with owner-only permissions. It lists up to 32 recent, non-empty, top-level pinned sessions and returns only user/assistant text for history. Pin and unpin changes update the bridge immediately. Tool events and other event types are omitted.

Install this bundle through DSH's own plugin manager. Do not copy it into the DSH profile or edit DSH profile configuration by hand. Once installed, Boring Notch needs to be rebuilt with the companion app changes. The bridge is otherwise inactive.

## Install through DSH Desktop

1. Copy this `DSHDesktop` directory to the target Mac. You can also unpack the distribution archive produced by `./package.sh`.
2. Open **Plugins** in DSH Desktop and choose **Add plugin**.
3. Enter the absolute path to the copied directory on that Mac.
4. Install the bundle, then make sure `boring-notch-dsh` is enabled in the Installed list.
5. Restart DSH Desktop if the plugin page reports that a restart is required. Launch Boring Notch after the helper is installed.

DSH's official plugin manager accepts an absolute local package directory and installs/enables the bundle through its own profile manager. The bundle has no npm dependencies or install scripts. Its Host code runs inside DSH with the current user's permissions, so review `lib/index.js` before installing a local development build.

DSH currently does not expose verified public APIs for opening a specific session, sending a prompt, or interrupting a run, so task rows remain read-only. A stopped/paused session is presented as completed because the public list API only supplies a `running` flag.

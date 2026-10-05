from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class MusicControlLatencyTests(unittest.TestCase):
    def test_native_controls_do_not_add_a_fixed_post_action_delay(self):
        source = (ROOT / "boringNotch/MediaControllers/NowPlayingController.swift").read_text()
        self.assertNotIn("Task.sleep(for: .milliseconds(200))", source)

    def test_native_action_reuses_the_accessibility_snapshot(self):
        source = (ROOT / "BoringNotchXPCHelper/BoringNotchXPCHelper.swift").read_text()
        start = source.index("    func run(_ action: String) -> Data? {")
        end = source.index("\n    }\n}", start)
        run = source[start:end]
        self.assertEqual(run.count("snapshot()"), 1)
        self.assertIn("cachedItems: snapshot.actionableItems", run)
        self.assertNotIn("snapshot())", run)
        snapshot_start = source.index("    private func snapshot() -> PlayerSnapshot {")
        snapshot_end = source.index("\n    func run(_ action: String)", snapshot_start)
        snapshot = source[snapshot_start:snapshot_end]
        self.assertEqual(snapshot.count("nativePlayerElements()"), 1)

if __name__ == "__main__":
    unittest.main()

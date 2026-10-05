import plistlib
import re
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
APP_BUNDLE_ID = "com.happyjoy95.boringnotch"
HELPER_BUNDLE_ID = f"{APP_BUNDLE_ID}.BoringNotchXPCHelper"


class IndependentDistributionTests(unittest.TestCase):
    def test_app_allows_bundled_sparkle_under_adhoc_release_signing(self):
        with (ROOT / "boringNotch/boringNotch.entitlements").open("rb") as entitlements_file:
            entitlements = plistlib.load(entitlements_file)
        self.assertTrue(entitlements.get("com.apple.security.cs.disable-library-validation"))

    def test_release_builder_checks_library_validation_entitlement_in_signed_app(self):
        build_script = (ROOT / ".github/scripts/build_fork_dmg.sh").read_text()
        self.assertIn("codesign --display --entitlements :-", build_script)
        self.assertIn("com.apple.security.cs.disable-library-validation", build_script)

    def test_app_and_helper_use_the_planned_fork_bundle_ids(self):
        project = (ROOT / "boringNotch.xcodeproj/project.pbxproj").read_text()
        self.assertEqual(project.count(f"PRODUCT_BUNDLE_IDENTIFIER = {APP_BUNDLE_ID};"), 2)
        self.assertEqual(project.count(f"PRODUCT_BUNDLE_IDENTIFIER = {HELPER_BUNDLE_ID};"), 2)

        for path in (
            ROOT / "BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift",
            ROOT / "boringNotch/XPCHelperClient/XPCHelperClient.swift",
        ):
            self.assertIn(HELPER_BUNDLE_ID, path.read_text())

        self.assertNotIn("com.github.happyjoy95.boringnotch", project)

    def test_sparkle_uses_only_the_fork_feed_and_enables_update_checks(self):
        with (ROOT / "boringNotch/Info.plist").open("rb") as plist_file:
            plist = plistlib.load(plist_file)
        self.assertEqual(
            plist["SUFeedURL"],
            "https://github.com/HappyJoy95/boring.notch/releases/latest/download/appcast.xml",
        )
        self.assertTrue(plist["SUPublicEDKey"])
        self.assertTrue(plist["SUEnableDownloaderService"])
        self.assertTrue(plist["SUEnableInstallerLauncherService"])
        self.assertTrue(plist["SUEnableAutomaticChecks"])
        self.assertTrue(plist["SUAutomaticallyUpdate"])
        self.assertNotIn("TheBoredTeam.github.io", plist["SUFeedURL"])

        app_source = (ROOT / "boringNotch/boringNotchApp.swift").read_text()
        settings_source = (ROOT / "boringNotch/components/Settings/SettingsView.swift").read_text()
        self.assertIn("SPUStandardUpdaterController", app_source)
        self.assertIn("CheckForUpdatesView", app_source)
        self.assertIn("UpdaterSettingsView", settings_source)
        self.assertIn("HappyJoy95/boring.notch/releases/latest/download/appcast.xml", app_source + settings_source + plist["SUFeedURL"])

    def test_project_version_uses_fork_suffix_for_every_target(self):
        project = (ROOT / "boringNotch.xcodeproj/project.pbxproj").read_text()
        versions = re.findall(r"MARKETING_VERSION\s*=\s*([^;]+);", project)
        self.assertEqual(versions, ["2.7.3-hj.2"] * 4)

    def test_release_metadata_requires_version_to_match_project_source(self):
        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / ".github/scripts/fork_release_metadata.py"),
                "--pbxproj",
                str(ROOT / "boringNotch.xcodeproj/project.pbxproj"),
                "--bundle-identifier",
                APP_BUNDLE_ID,
                "--version",
                "2.7.3-hj.2",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("tag=v2.7.3-hj.2", result.stdout)
        self.assertIn("upstream_version=2.7.3", result.stdout)
        self.assertIn("build_number=273", result.stdout)

        invalid = subprocess.run(
            [
                sys.executable,
                str(ROOT / ".github/scripts/fork_release_metadata.py"),
                "--pbxproj",
                str(ROOT / "boringNotch.xcodeproj/project.pbxproj"),
                "--bundle-identifier",
                APP_BUNDLE_ID,
                "--version",
                "2.7.3",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("Invalid fork version", invalid.stderr)

    def test_release_workflow_tags_the_built_source_and_publishes_sparkle_updates(self):
        workflow = (ROOT / ".github/workflows/fork-release.yml").read_text()
        for expected in (
            "workflow_dispatch:",
            "github.ref == 'refs/heads/main'",
            "fork_release_metadata.py",
            'git tag -a "$TAG" "$SOURCE_SHA"',
            "build_fork_dmg.sh",
            "SPARKLE_EDDSA_PRIVATE_KEY",
            "generate_appcast",
            "appcast.xml",
            "macos-universal.zip",
            "Fixed an issue that prevented the app from opening after macOS security authorization.",
            "Ensure the build number increases for each release",
            "Build number: $BUILD_NUMBER",
            "BUILD_NUMBER <= LATEST_BUILD",
            'gh release create "$TAG"',
            "--verify-tag",
            "TheBoredTeam/boring.notch",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, workflow)
        self.assertNotIn("actions/deploy-pages", workflow)

        build_script = (ROOT / ".github/scripts/build_fork_dmg.sh").read_text()
        self.assertIn('DMG_PATH="$OUTPUT_DIRECTORY/boringNotch.dmg"', build_script)
        self.assertIn('shasum -a 256 "$DMG_PATH"', build_script)
        self.assertIn('"$DMG_PATH.sha256"', build_script)
        self.assertIn("macos-universal.zip", build_script)

    def test_manual_build_uploads_dmg_and_checksum_as_actions_artifacts(self):
        path = ROOT / ".github/workflows/fork-manual-build.yml"
        self.assertTrue(path.is_file(), "fork manual build workflow is missing")
        workflow = path.read_text()
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("build_fork_dmg.sh", workflow)
        self.assertIn("actions/upload-artifact", workflow)
        build_script = (ROOT / ".github/scripts/build_fork_dmg.sh").read_text()
        self.assertIn("boringNotch.dmg", build_script)
        self.assertIn('"$DMG_PATH.sha256"', build_script)

    def test_dmg_builder_runs_with_the_hash_pinned_virtual_environment(self):
        build_script = (ROOT / ".github/scripts/build_fork_dmg.sh").read_text()
        activation = 'source "$RUNNER_TEMP/dmg-venv/bin/activate"'
        create_dmg = './Configuration/dmg/create_dmg.sh "$APP_DEST" "$DMG_PATH"'
        self.assertIn(activation, build_script)
        self.assertLess(build_script.index(activation), build_script.index(create_dmg))

    def test_ci_builds_and_runs_repository_tests(self):
        workflow = (ROOT / ".github/workflows/cicd.yml").read_text()
        self.assertIn("macos-26", workflow)
        self.assertIn("xcodebuild clean build", workflow)
        self.assertIn("python3 -m unittest discover -s .github/scripts/tests", workflow)

    def test_readme_identifies_the_fork_and_explains_install_and_upstream(self):
        readme = (ROOT / "README.md").read_text()
        for expected in (
            "https://github.com/HappyJoy95/boring.notch",
            "https://github.com/TheBoredTeam/boring.notch",
            "独立维护 Fork",
            "官方 Homebrew Cask",
            "2.7.3-hj.1",
            "Sparkle",
            "自动检查",
            "Codex、WorkBuddy、DSH 和 MiMo Desktop",
            "歌词显示",
            "QQ 音乐和网易云音乐控制",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, readme)
        self.assertNotIn("Fork Release and Sparkle Updates", readme)

    def test_user_facing_security_and_onboarding_content_uses_fork_identity(self):
        security = (ROOT / "SECURITY.md").read_text()
        feature_request = (ROOT / ".github/ISSUE_TEMPLATE/1-feature-request-form.yml").read_text()
        welcome = (ROOT / "boringNotch/components/Onboarding/WelcomeView.swift").read_text()
        localizations = (ROOT / "boringNotch/Localizable.xcstrings").read_text()
        self.assertNotIn("The Bored Team", security)
        self.assertIn("HappyJoy95/boring.notch/issues", feature_request)
        self.assertNotIn("TheBoredTeam/boring.notch/issues", feature_request)
        self.assertNotIn('Image("theboringteam")', welcome)
        self.assertNotIn("not so boring not.people", localizations)
        self.assertFalse((ROOT / "boringNotch/Assets.xcassets/theboringteam.imageset").exists())

    def test_pages_sparkle_and_upstream_release_workflows_are_disabled_on_fork(self):
        for name in ("nightly.yml", "release.yml", "static.yml"):
            workflow = (ROOT / ".github/workflows" / name).read_text()
            self.assertIn("github.repository == 'TheBoredTeam/boring.notch'", workflow)


if __name__ == "__main__":
    unittest.main()

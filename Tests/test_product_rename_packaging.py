from pathlib import Path
import unittest


ROOT = Path(__file__).parents[1]


class ProductRenamePackagingTests(unittest.TestCase):
    def test_build_uses_new_display_name_and_preserves_binary_identity(self):
        script = (ROOT / "Scripts/build-app.sh").read_text()

        self.assertIn('product_name="Focus Queue"', script)
        self.assertIn("CFBundleExecutable -string ECCFocusQueue", script)
        self.assertIn("CFBundleIdentifier -string com.haelyra.ecc-focus-queue", script)
        self.assertIn("Focus Queue reads your local task dashboard", script)

    def test_install_and_release_scripts_use_renamed_bundle(self):
        for relative in (
            "Scripts/install.sh",
            "Scripts/Install.command",
            "Scripts/package-release.sh",
        ):
            with self.subTest(script=relative):
                script = (ROOT / relative).read_text()
                self.assertIn("Focus Queue.app", script)
                self.assertNotIn("ECC Focus Queue.app", script)
        release = (ROOT / "Scripts/package-release.sh").read_text()
        self.assertIn("FocusQueue-0.3.4-beta-", release)
        self.assertNotIn("ECCFocusQueue-0.3.4-beta-", release)

    def test_map_launcher_prefers_renamed_bundle_with_legacy_fallback(self):
        script = (ROOT / "Scripts/focus-queue-map").read_text()
        renamed = '$HOME/Applications/Focus Queue.app/Contents/MacOS/focus-queue-map'
        legacy = '$HOME/Applications/ECC Focus Queue.app/Contents/MacOS/focus-queue-map'

        self.assertIn(renamed, script)
        self.assertIn(legacy, script)
        self.assertLess(script.index(renamed), script.index(legacy))

    def test_user_facing_docs_use_renamed_product(self):
        readme = (ROOT / "README.md").read_text()
        beta = (ROOT / "Docs/BETA_README.txt").read_text()

        self.assertTrue(readme.startswith("# Focus Queue\n"))
        self.assertTrue(beta.startswith("Focus Queue 0.3.4 public beta\n"))
        self.assertIn('xattr -dr com.apple.quarantine "Focus Queue Beta"', beta)
        self.assertIn('xattr -dr com.apple.quarantine "Focus Queue Beta"', readme)

    def test_bundled_files_are_writable_so_testers_can_clear_quarantine(self):
        script = (ROOT / "Scripts/build-app.sh").read_text()

        self.assertIn('/usr/bin/install -m 0644 "$build_dir/checkouts/Ink/LICENSE"', script)
        self.assertNotIn('/bin/cp "$build_dir/checkouts/', script)


if __name__ == "__main__":
    unittest.main()

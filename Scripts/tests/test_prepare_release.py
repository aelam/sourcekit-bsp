import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_release import VERSION_FILE, next_version, prepare_manual_release, plan_automatic_release, read_version, release_version_key


class VersionTests(unittest.TestCase):
    def test_increment_choices(self):
        self.assertEqual(next_version("0.2.8", "patch"), "0.2.9")
        self.assertEqual(next_version("0.2.8", "minor"), "0.3.0")
        self.assertEqual(next_version("0.2.8", "major"), "1.0.0")
        self.assertEqual(next_version("1.9.99", "patch"), "1.9.100")

    def test_invalid_increment(self):
        for bump in (None, "", "prerelease", "PATCH", "patch\n"):
            with self.subTest(bump=bump), self.assertRaisesRegex(ValueError, "Choose patch"):
                next_version("0.2.8", bump)

    def test_invalid_current_version(self):
        for version in ("01.2.3", "1.2", "1.2.3-beta", "1.2.3\n", "1.2.-3"):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "stable"):
                next_version(version, "patch")

    def test_version_declaration_must_be_unique(self):
        for source in ("", 'static let current = "0.2.8"\n' * 2):
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, "Expected one"):
                read_version(source)

    def test_release_versions_follow_semantic_precedence(self):
        versions = [
            "0.2.8", "0.2.9-alpha", "0.2.9-alpha.1", "0.2.9-alpha.beta",
            "0.2.9-beta.2", "0.2.9-beta.11", "0.2.9-rc.1", "0.2.9", "0.3.0", "1.0.0",
        ]
        for previous, version in zip(versions, versions[1:]):
            with self.subTest(previous=previous, version=version):
                self.assertLess(release_version_key(previous), release_version_key(version))
        self.assertEqual(release_version_key("1.0.0+first"), release_version_key("1.0.0+second"))

    def test_invalid_release_versions_are_rejected(self):
        for version in ("01.2.3", "1.2.3.4", "1.2.3-", "1.2.3-beta..1", "1.2.3-beta.01", "1.2.3+", "1.2.3\n"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                release_version_key(version)


class ReleasePreparationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="sourcekit-release-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "checkout"
        self.remote = Path(temporary.name) / "remote.git"
        self.root.mkdir()
        self.version_path = self.root / VERSION_FILE
        self.version_path.parent.mkdir(parents=True)
        self.git("init", "--bare", str(self.remote))
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release Tests")
        self.git("config", "user.email", "release-tests@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        self.git("config", "core.hooksPath", str(self.root / "no-hooks"))
        self.git("remote", "add", "origin", str(self.remote))
        self.write_version("0.2.8")
        script = self.root / "Scripts" / "prepare_release.py"
        script.parent.mkdir()
        shutil.copyfile(Path(__file__).resolve().parents[1] / "prepare_release.py", script)
        self.git("add", ".")
        self.git("commit", "-m", "Set fixture version")
        self.git("push", "-u", "origin", "main")
        self.base_commit = self.git("rev-parse", "HEAD")

    def git(self, *args):
        return subprocess.check_output(
            ["git", *args], cwd=self.root, text=True, stderr=subprocess.PIPE
        ).strip()

    def write_version(self, version):
        self.version_path.write_text(
            f'enum SourceKitBSPVersion {{\n    static let current = "{version}"\n}}\n'
        )

    def prepare(self, bump="patch", base_commit=None, run_id="12345"):
        return prepare_manual_release(self.root, bump, base_commit or self.base_commit, run_id)

    def automatic(self, before=None, ref_type="branch", ref_name="main"):
        return plan_automatic_release(self.root, before or self.base_commit, ref_type, ref_name)

    def test_only_the_version_is_committed_and_pushed(self):
        before = self.version_path.read_text()
        plan = self.prepare()
        commit = self.git("rev-parse", "HEAD")
        self.assertEqual(plan, {
            "release_version": "0.2.9", "tag_name": "v0.2.9",
            "commit": commit, "should_publish": "true",
        })
        self.assertEqual(self.version_path.read_text(), before.replace('"0.2.8"', '"0.2.9"'))
        self.assertEqual(self.git("diff-tree", "--no-commit-id", "--name-only", "-r", commit), VERSION_FILE)
        self.assertEqual(self.git("rev-parse", f"{commit}^"), self.base_commit)
        self.assertEqual(self.git("--git-dir", str(self.remote), "rev-parse", "main"), commit)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.git("tag", "--list"), "")
        self.assertEqual(self.automatic()["should_publish"], "false")

    def test_retry_reuses_commit_even_after_main_advances(self):
        plan = self.prepare()
        self.assertEqual(self.prepare(), plan)
        self.git("tag", "-a", plan["tag_name"], "-m", "Fixture release")
        self.write_version("0.3.0")
        self.git("add", VERSION_FILE)
        self.git("commit", "-m", "Advance main")
        self.git("push", "origin", "main")
        advanced = self.git("rev-parse", "HEAD")
        self.git("checkout", "--detach", self.base_commit)
        self.assertEqual(self.prepare(), plan)
        self.assertEqual(self.git("--git-dir", str(self.remote), "rev-parse", "main"), advanced)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.base_commit)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_stale_run_cannot_lower_main_version(self):
        self.write_version("0.3.0")
        self.git("add", VERSION_FILE)
        self.git("commit", "-m", "Advance main version")
        self.git("push", "origin", "main")
        advanced = self.git("rev-parse", "HEAD")
        self.git("checkout", "--detach", self.base_commit)
        with self.assertRaisesRegex(ValueError, "main advanced"):
            self.prepare()
        self.assertEqual(self.git("--git-dir", str(self.remote), "rev-parse", "main"), advanced)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_existing_tag_stops_new_preparation_without_mutation(self):
        self.git("tag", "-a", "v0.2.9", "-m", "Existing fixture tag")
        before = self.version_path.read_text()
        with self.assertRaisesRegex(ValueError, "Tag v0.2.9 already exists"):
            self.prepare()
        self.assertEqual(self.version_path.read_text(), before)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_dirty_checkout_cannot_enter_the_version_commit(self):
        (self.root / "local.txt").write_text("local change\n")
        with self.assertRaisesRegex(ValueError, "clean checkout"):
            self.prepare()
        self.assertEqual(self.git("rev-parse", "HEAD"), self.base_commit)

    def test_retry_rejects_a_tag_on_another_commit(self):
        self.prepare()
        self.git("tag", "v0.2.9", self.base_commit)
        with self.assertRaisesRegex(ValueError, "already points to another commit"):
            self.prepare()

    def test_retry_rejects_unrelated_changes_with_the_same_marker(self):
        self.write_version("0.2.9")
        with self.version_path.open("a") as source:
            source.write("// Unrelated fixture change.\n")
        self.git("add", VERSION_FILE)
        self.git("commit", "-m", "Unrelated change", "-m", "Release-Run: 12345")
        self.git("push", "origin", "main")
        with self.assertRaisesRegex(ValueError, "does not match this release run"):
            self.prepare()

    def test_invalid_run_identity_stops_preparation(self):
        before = self.version_path.read_text()
        with self.assertRaisesRegex(ValueError, "GITHUB_SHA"):
            self.prepare(base_commit="main")
        with self.assertRaisesRegex(ValueError, "GITHUB_RUN_ID"):
            self.prepare(run_id="0")
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare(base_commit="f" * 40)
        self.assertEqual(self.version_path.read_text(), before)

    def test_automatic_release_compares_the_entire_push(self):
        self.write_version("0.2.9")
        self.git("add", VERSION_FILE)
        self.git("commit", "-m", "Update version through a PR")
        bumped = self.git("rev-parse", "HEAD")
        self.git("commit", "--allow-empty", "-m", "Another change in the same push")
        commit = self.git("rev-parse", "HEAD")
        self.assertEqual(self.automatic()["should_publish"], "true")
        self.assertEqual(self.automatic()["commit"], commit)
        self.assertEqual(self.automatic(before=bumped)["should_publish"], "false")
        self.git("tag", "-a", "v0.2.9", "-m", "Fixture release")
        self.assertEqual(self.automatic()["should_publish"], "true")
        self.git("commit", "--allow-empty", "-m", "Advance fixture")
        with self.assertRaisesRegex(ValueError, "already points to another commit"):
            self.automatic()

    def test_tag_releases_require_matching_version_and_support_prereleases(self):
        self.write_version("0.3.0-beta.1")
        self.git("add", VERSION_FILE)
        self.git("commit", "-m", "Set prerelease version")
        self.git("tag", "-a", "v0.3.0-beta.1", "-m", "Fixture prerelease")
        plan = self.automatic(ref_type="tag", ref_name="v0.3.0-beta.1")
        self.assertEqual(plan["should_publish"], "true")
        self.assertEqual(plan["tag_name"], "v0.3.0-beta.1")
        with self.assertRaisesRegex(ValueError, "does not match version"):
            self.automatic(ref_type="tag", ref_name="v0.3.0")

    def test_automatic_release_rejects_a_version_decrease(self):
        self.write_version("0.1.99")
        self.git("add", VERSION_FILE)
        self.git("commit", "-m", "Lower the fixture version")
        with self.assertRaisesRegex(ValueError, "must be greater than 0.2.8"):
            self.automatic()
        self.assertEqual(self.git("tag", "--list"), "")

    def test_automatic_release_allows_prerelease_progression_but_not_regression(self):
        self.write_version("0.3.0-beta.2")
        self.git("add", VERSION_FILE)
        self.git("commit", "-m", "Set fixture prerelease")
        before = self.git("rev-parse", "HEAD")
        self.write_version("0.3.0-beta.11")
        self.git("add", VERSION_FILE)
        self.git("commit", "-m", "Advance fixture prerelease")
        self.assertEqual(self.automatic(before=before)["should_publish"], "true")
        before = self.git("rev-parse", "HEAD")
        self.write_version("0.3.0-beta.3")
        self.git("add", VERSION_FILE)
        self.git("commit", "-m", "Lower fixture prerelease")
        with self.assertRaisesRegex(ValueError, "must be greater"):
            self.automatic(before=before)

    def test_automatic_release_rejects_a_change_to_only_build_metadata(self):
        self.write_version("0.2.8+build.1")
        self.git("add", VERSION_FILE)
        self.git("commit", "-m", "Change fixture build metadata")
        with self.assertRaisesRegex(ValueError, "must be greater"):
            self.automatic()

    def test_automatic_releases_reject_unrelated_refs_and_invalid_before(self):
        with self.assertRaisesRegex(ValueError, "require main"):
            self.automatic(ref_name="feature")
        with self.assertRaisesRegex(ValueError, "BEFORE_SHA"):
            self.automatic(before="main")

    def test_cli_writes_outputs_for_the_pushed_commit(self):
        output = self.root.parent / "github-output"
        result = subprocess.run([sys.executable, str(self.root / "Scripts" / "prepare_release.py")], env={
            **os.environ, "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
            "GITHUB_SHA": self.base_commit, "GITHUB_RUN_ID": "12345",
            "BUMP_TYPE": "minor", "GITHUB_OUTPUT": str(output),
        }, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Prepared v0.3.0", result.stdout)
        self.assertEqual(dict(line.split("=", 1) for line in output.read_text().splitlines()), {
            "release_version": "0.3.0", "tag_name": "v0.3.0",
            "commit": self.git("rev-parse", "HEAD"), "should_publish": "true",
        })


if __name__ == "__main__":
    unittest.main()

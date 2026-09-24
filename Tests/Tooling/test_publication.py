"""Boundary tests using throwaway repositories and synthetic sensitive values."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.write("README.md", "Public documentation.\n")
        self.git("add", "README.md")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True).stdout

    def write(self, path, value):
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(value)
        return destination

    def run_tool(self, name, *args):
        return subprocess.run([sys.executable, str(SCRIPTS / name), *args], cwd=self.root, capture_output=True, text=True)

    def package(self):
        return self.run_tool("package-source.py", "--output", "source.zip")

    def test_archive_uses_index_and_preserves_executable_mode(self):
        script = self.write("scripts/build.sh", "#!/bin/sh\nexit 0\n")
        script.chmod(0o755)
        self.git("add", "scripts/build.sh")
        self.write("README.md", "Unstaged private draft.\n")
        self.write(".private/notes.md", "Private notes.\n")
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(self.root / "source.zip") as archive:
            self.assertEqual(set(archive.namelist()), {"Within-source/README.md", "Within-source/scripts/build.sh"})
            self.assertEqual(archive.read("Within-source/README.md"), b"Public documentation.\n")
            self.assertEqual(archive.getinfo("Within-source/scripts/build.sh").external_attr >> 16, 0o100755)

    def test_force_added_private_or_unknown_paths_are_refused(self):
        self.write(".gitignore", "private-*\n")
        for path in ("private-report.md", "memory-bank/activeContext.md", ".agents/skills/start/SKILL.md", "docs/internal.md", "Sources/private-notes.swift"):
            with self.subTest(path=path):
                self.write(path, "Working context.\n")
                self.git("add", "-f", path)
                for tool in ("publication_policy.py", "package-source.py"):
                    result = self.run_tool(tool, *(["--output", "source.zip"] if tool.startswith("package") else []))
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn(path, result.stdout + result.stderr)
                self.assertFalse((self.root / "source.zip").exists())
                self.git("rm", "--cached", path)

    def test_synthetic_secrets_and_personal_paths_are_refused_without_echo(self):
        values = [
            "gh" + "p_" + "A" * 36,
            "sk-" + "proj-" + "a" * 40,
            "-----BEGIN " + "PRIVATE KEY-----",
            "AK" + "IA" + "A" * 16,
            "xox" + "b-" + "1" * 24,
            "/" + "Users/fixture/private.txt",
            "C:" + "\\Users\\fixture\\private.txt",
        ]
        for value in values:
            with self.subTest(kind=values.index(value)):
                self.write("README.md", value + "\n")
                self.git("add", "README.md")
                result = self.package()
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(value, result.stdout + result.stderr)
                self.assertFalse((self.root / "source.zip").exists())

    def test_symlinks_are_refused(self):
        (self.root / "README.md").unlink()
        (self.root / "README.md").symlink_to("private-target")
        self.git("add", "README.md")
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("regular files", result.stderr)

    def test_unexpected_binary_is_refused(self):
        (self.root / "README.md").write_bytes(b"private\0binary")
        self.git("add", "README.md")
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("binary", result.stderr)

    def test_historical_private_file_is_found_after_deletion(self):
        self.write("memory-bank/activeContext.md", "Private working context.\n")
        self.git("add", "memory-bank/activeContext.md")
        self.git("commit", "-qm", "Fixture with restricted path")
        self.git("rm", "memory-bank/activeContext.md")
        self.git("commit", "-qm", "Remove restricted path")
        self.assertEqual(self.run_tool("publication_policy.py").returncode, 0)
        result = self.run_tool("publication_policy.py", "--all-history")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("allowlist", result.stderr)

    def test_clean_history_and_metadata_check(self):
        self.git("commit", "-qm", "Public fixture")
        self.assertEqual(self.run_tool("publication_policy.py", "--all-history").returncode, 0)
        self.git("commit", "--allow-empty", "-qm", "private path /" + "home/fixture/notes")
        result = self.run_tool("publication_policy.py", "--all-history")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("personal home path", result.stderr)
        self.assertNotIn("fixture/notes", result.stderr)

    def test_output_symlink_is_not_followed(self):
        (self.root / "source.zip").symlink_to("private-destination.zip")
        self.assertNotEqual(self.package().returncode, 0)
        self.assertFalse((self.root / "private-destination.zip").exists())

    def test_output_cannot_replace_source_or_existing_archive(self):
        result = self.run_tool("package-source.py", "--output", "README.md")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "README.md").read_text(), "Public documentation.\n")
        self.assertEqual(self.package().returncode, 0)
        original = (self.root / "source.zip").read_bytes()
        self.assertNotEqual(self.package().returncode, 0)
        self.assertEqual((self.root / "source.zip").read_bytes(), original)


if __name__ == "__main__":
    unittest.main()

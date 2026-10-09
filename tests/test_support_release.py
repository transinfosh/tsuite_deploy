"""Verify the upstream installer boundary with isolated release fixtures."""
import hashlib
import io
import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class SupportReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.control = self.root / "control-node"
        self.control.mkdir()
        for name in ("install-support-release.sh", "prepare-support-access.sh", "install-support-console.sh"):
            shutil.copyfile(ROOT / "control-node" / name, self.control / name)
        self.archive = self.root / "release.tar.gz"
        self.marker = self.root / "ran"
        body = b'#!/usr/bin/env bash\nprintf "%s\\n" "$@"\nprintf ran > "$TEST_MARKER"\nexit "${TEST_EXIT_CODE:-0}"\n'
        with tarfile.open(self.archive, "w:gz") as archive:
            for name in ("prepare-support-access.sh", "install-support-console.sh"):
                member = tarfile.TarInfo("tsuite-support-v0.1.0/control/" + name)
                member.size = len(body)
                member.mode = 0o755
                archive.addfile(member, io.BytesIO(body))
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        (self.control / "support-release.env").write_text("TSUITE_SUPPORT_VERSION=0.1.0\nTSUITE_SUPPORT_SHA256=" + digest + "\n")
        self.env = {**os.environ, "TSUITE_SUPPORT_ARCHIVE": str(self.archive), "TEST_MARKER": str(self.marker)}

    def run_wrapper(self, name, *arguments):
        return subprocess.run(["bash", str(self.control / name), *arguments], env=self.env, capture_output=True, text=True)

    def test_verified_release_preserves_argument_boundaries_and_legacy_options(self):
        result = self.run_wrapper("prepare-support-access.sh", "--operator-user", "a value with spaces")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["--deployment-service-permissions", "--operator-user", "a value with spaces"])
        self.assertTrue(self.marker.exists())
        result = self.run_wrapper("install-support-console.sh", "--public-host", "support.example.com")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[:2], ["--https-proxy", "http://127.0.0.1:18080"])

    def test_wrong_archive_is_rejected_before_execution(self):
        with self.archive.open("ab") as handle:
            handle.write(b"tampered")
        result = self.run_wrapper("prepare-support-access.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_install_failure_is_returned(self):
        self.env["TEST_EXIT_CODE"] = "23"
        result = self.run_wrapper("install-support-console.sh")
        self.assertEqual(result.returncode, 23)

    def test_download_uses_pinned_release_url(self):
        self.env.pop("TSUITE_SUPPORT_ARCHIVE")
        binary = self.root / "bin"
        binary.mkdir()
        curl = binary / "curl"
        curl.write_text('#!/usr/bin/env bash\nset -eu\nwhile (($#)); do\n  case "$1" in\n    --output) target="$2"; shift ;;\n    https://*) printf "%s" "$1" > "$TEST_URL" ;;\n  esac\n  shift\ndone\ncp "$TEST_ARCHIVE" "$target"\n')
        curl.chmod(0o755)
        url = self.root / "url"
        self.env.update(PATH=str(binary) + os.pathsep + self.env["PATH"], TEST_URL=str(url), TEST_ARCHIVE=str(self.archive))
        result = self.run_wrapper("prepare-support-access.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(url.read_text(), "https://github.com/transinfosh/tsuite-support/releases/download/v0.1.0/tsuite-support-v0.1.0.tar.gz")

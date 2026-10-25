"""Exercise the pre-deployment image gate without a Docker daemon or remote registry."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CHECKER = Path(__file__).resolve().parents[1] / "tools/check-registry-images.py"


class RegistryImageGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.calls = self.root / "calls.jsonl"
        fake_docker = self.root / "docker"
        fake_docker.write_text(
            "#!/usr/bin/env python3\n"
            "import json,os,sys\n"
            "with open(os.environ['REGISTRY_TEST_CALLS'], 'a') as log:\n"
            " log.write(json.dumps({'args':sys.argv[1:], 'no_proxy':os.environ['NO_PROXY']})+'\\n')\n"
            "sys.exit(1 if sys.argv[-1].endswith(':missing') else 0)\n"
        )
        fake_docker.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": str(self.root) + os.pathsep + os.environ["PATH"],
            "NO_PROXY": "localhost,internal.example",
            "REGISTRY_TEST_CALLS": str(self.calls),
        }

    def run_gate(self, images):
        return subprocess.run(
            [sys.executable, str(CHECKER)],
            input="\n".join(images),
            text=True,
            capture_output=True,
            env=self.env,
            check=False,
        )

    def test_checks_deduplicated_compose_images_and_bypasses_proxy(self):
        image = "registry.trinfo.net/transinfosh/quality:0.0.31"
        digest = "registry.trinfo.net/library/redis@sha256:" + "a" * 64
        result = self.run_gate([image, digest, image])
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        self.assertEqual({c["args"][-1] for c in calls}, {image, digest})
        self.assertTrue(all(c["args"][:2] == ["manifest", "inspect"] for c in calls))
        self.assertTrue(all("registry.trinfo.net" in c["no_proxy"] for c in calls))
        self.assertTrue(all("internal.example" in c["no_proxy"] for c in calls))

    def test_upstream_and_unversioned_images_are_rejected_before_network_access(self):
        result = self.run_gate(
            [
                "ghcr.io/transinfosh/quality:0.0.31",
                "redis:8.6-alpine",
                "registry.trinfo.net/transinfosh/quality",
            ]
        )
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.calls.exists())

    def test_missing_version_fails_without_fallback_or_version_change(self):
        image = "registry.trinfo.net/transinfosh/quality:missing"
        result = self.run_gate([image])
        self.assertEqual(result.returncode, 1)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual([c["args"] for c in calls], [["manifest", "inspect", image]])
        self.assertIn("mirror this exact version", result.stderr)

    def test_empty_compose_inventory_is_an_error(self):
        result = self.run_gate([])
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()

import base64
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + ".py"))
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


local = module("patch")
remote = module("remote")


def encoded(value):
    return base64.b64encode(value).decode()


class ScopeTests(unittest.TestCase):
    def test_scope(self):
        for path in ["tai/runtime/agents/data.py", "tai/prompts/chart.md"]:
            self.assertTrue(local.allowed(path, "tai"))
        for path in [
            "tai/hooks.py",
            "tai/doctype/item/item.py",
            "tai/patches/fix.py",
            "pyproject.toml",
            "tai/public/page.js",
            "tai/../tbi/query.py",
            "/tai/query.py",
            "tbi/query.py",
            "tai/install.py",
            "tai/requirements.txt",
        ]:
            with self.subTest(path=path):
                self.assertFalse(local.allowed(path, "tai"))

    def test_committed_content_and_added_file_rejection(self):
        with tempfile.TemporaryDirectory() as d:

            def git(*args):
                return subprocess.check_output(["git", "-C", d, *args])

            git("init", "-q")
            git("config", "user.email", "test@example.invalid")
            git("config", "user.name", "Test")
            p = Path(d) / "tai/query.py"
            p.parent.mkdir()
            p.write_text("value = 1\n")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD").decode().strip()
            p.write_text("value = 2\n")
            git("commit", "-qam", "fix")
            commit = git("rev-parse", "HEAD").decode().strip()
            p.write_text("uncommitted secret")
            result = local.bundle(d, "tai", base, commit)
            self.assertEqual(
                base64.b64decode(result["files"][0]["after"]), b"value = 2\n"
            )
            (p.parent / "new.py").write_text("value=3")
            git("add", ".")
            git("commit", "-qm", "add")
            with self.assertRaises(ValueError):
                local.bundle(d, "tai", commit, "HEAD")


class ControllerBackupTests(unittest.TestCase):
    def test_offhost_failure_never_dispatches_apply(self):
        from types import SimpleNamespace

        with tempfile.TemporaryDirectory() as d:
            args = SimpleNamespace(
                identity=None, host="test-host", records=d, project="frappe-customer"
            )
            directory = Path(d) / "test-host" / "frappe-customer"
            directory.mkdir(parents=True)
            (directory / "fix-1.json").write_text("existing backup")
            response = SimpleNamespace(
                returncode=0, stdout=json.dumps({"backup": {"original": "source"}})
            )
            with patch.object(local.subprocess, "run", return_value=response) as run:
                with self.assertRaises(FileExistsError):
                    local.dispatch(args, {"action": "apply", "id": "fix-1"})
                self.assertEqual(run.call_count, 1)
                self.assertEqual(
                    json.loads(run.call_args.kwargs["input"])["action"], "prepare"
                )

    def test_offhost_backup_precedes_apply(self):
        from types import SimpleNamespace

        with tempfile.TemporaryDirectory() as d:
            args = SimpleNamespace(
                identity=None, host="test-host", records=d, project="frappe-customer"
            )

            def command(*a, **kw):
                request = json.loads(kw["input"])
                if request["action"] == "prepare":
                    return SimpleNamespace(
                        returncode=0,
                        stdout=json.dumps({"backup": {"original": "source"}}),
                    )
                target = Path(d) / "test-host" / "frappe-customer" / "fix-1.json"
                self.assertEqual(json.loads(target.read_text())["original"], "source")
                self.assertEqual(target.stat().st_mode & 0o777, 0o600)
                return SimpleNamespace(
                    returncode=0, stdout=json.dumps({"status": "applied"})
                )

            with patch.object(local.subprocess, "run", side_effect=command):
                self.assertEqual(
                    local.dispatch(args, {"action": "apply", "id": "fix-1"}), 0
                )

    def test_prepare_failure_never_dispatches_apply(self):
        from types import SimpleNamespace

        args = SimpleNamespace(
            identity=None,
            host="test-host",
            records="/unused",
            project="frappe-customer",
        )
        with patch.object(
            local.subprocess,
            "run",
            return_value=SimpleNamespace(returncode=1, stdout='{"status":"failed"}'),
        ) as run:
            self.assertEqual(
                local.dispatch(args, {"action": "apply", "id": "fix-1"}), 1
            )
            self.assertEqual(run.call_count, 1)


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.rows = [
            {
                "Id": name,
                "Image": "image-id",
                "Config": {
                    "Image": "image@sha256:test",
                    "Labels": {"com.docker.compose.service": service},
                },
                "State": {"Running": True},
            }
            for name, service in [("web", "backend"), ("worker", "queue-tai-runtime")]
        ]
        self.request = {
            "action": "prepare",
            "project": "frappe-customer",
            "id": "fix-1",
            "app": "tai",
            "base": "base",
            "commit": "commit",
            "site": "test.localhost",
            "files": [
                {
                    "path": "tai/query.py",
                    "before": encoded(b"value=1\n"),
                    "after": encoded(b"value=2\n"),
                }
            ],
        }
        self.data = {r["Id"]: b"value=1\n" for r in self.rows}
        self.events = []
        self.stack = []
        for name, replacement in [
            ("containers", lambda *a, **k: self.rows),
            ("read", self.read),
            ("run", self.command),
            ("write", self.write),
            ("health", lambda *a: self.events.append("health")),
        ]:
            m = patch.object(remote, name, replacement)
            m.start()
            self.stack.append(m)

    def tearDown(self):
        for m in reversed(self.stack):
            m.stop()
        self.temp.cleanup()

    def read(self, req, rows):
        return {
            r["Id"]: [
                {
                    "path": "tai/query.py",
                    "data": encoded(self.data[r["Id"]]),
                    "mode": 0o644,
                    "uid": 1000,
                    "gid": 1000,
                }
            ]
            for r in rows
        }

    def command(self, *args, **kwargs):
        self.events.append(args[:2])
        return b""

    def write(self, cid, app, files):
        self.data[cid] = base64.b64decode(files[0]["data"])

    def process(self, action):
        return remote.process({**self.request, "action": action}, self.directory)

    def test_prepare_does_not_modify_files(self):
        result = self.process("prepare")
        self.assertEqual(result["status"], "prepared")
        self.assertIn("backup", result)
        self.assertEqual(set(self.data.values()), {b"value=1\n"})
        state = json.loads((self.directory / "fix-1.json").read_text())
        self.assertNotIn("Image", state["containers"][0])
        self.assertEqual((self.directory / "fix-1.json").stat().st_mode & 0o777, 0o600)

    def test_apply_and_explicit_rollback(self):
        self.process("prepare")
        self.process("apply")
        self.assertEqual(set(self.data.values()), {b"value=2\n"})
        self.process("rollback")
        self.assertEqual(set(self.data.values()), {b"value=1\n"})
        self.assertEqual(
            json.loads((self.directory / "fix-1.json").read_text())["status"],
            "rolled_back",
        )

    def test_drift_rejected_before_stop(self):
        self.data["worker"] = b"other fix"
        with self.assertRaises(ValueError):
            self.process("prepare")
        self.assertNotIn(("docker", "stop"), self.events)

    def test_drift_between_prepare_and_apply(self):
        self.process("prepare")
        self.data["worker"] = b"changed"
        with self.assertRaises(ValueError):
            self.process("apply")
        self.assertNotIn(("docker", "stop"), self.events)

    def test_unprepared_apply_rejected(self):
        with self.assertRaises(FileNotFoundError):
            self.process("apply")
        self.assertNotIn(("docker", "stop"), self.events)

    def test_partial_failure_restores_all_containers(self):
        self.process("prepare")
        calls = 0

        def fail_once(cid, app, files):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise RuntimeError("Copy failed")
            self.write(cid, app, files)

        with patch.object(remote, "write", fail_once), self.assertRaises(RuntimeError):
            self.process("apply")
        self.assertEqual(set(self.data.values()), {b"value=1\n"})
        self.assertEqual(
            json.loads((self.directory / "fix-1.json").read_text())["status"],
            "rolled_back",
        )

    def test_health_failure_restores_all_containers(self):
        self.process("prepare")
        with (
            patch.object(
                remote, "health", side_effect=[RuntimeError("health failed"), None]
            ),
            self.assertRaises(RuntimeError),
        ):
            self.process("apply")
        self.assertEqual(set(self.data.values()), {b"value=1\n"})

    def test_failed_rollback_is_recorded(self):
        self.process("prepare")
        with (
            patch.object(remote, "write", side_effect=RuntimeError("write failed")),
            self.assertRaises(RuntimeError),
        ):
            self.process("apply")
        self.assertEqual(
            json.loads((self.directory / "fix-1.json").read_text())["status"],
            "rollback_failed",
        )

    def test_second_active_patch_rejected(self):
        self.process("prepare")
        self.process("apply")
        with self.assertRaises(ValueError):
            remote.process({**self.request, "id": "fix-2"}, self.directory)

    def test_recreated_container_rollback_rejected(self):
        self.process("prepare")
        self.process("apply")
        self.rows[0]["Id"] = "replacement"
        with self.assertRaises(ValueError):
            self.process("rollback")

    def test_unsafe_direct_request_rejected(self):
        self.request["files"][0]["path"] = "tai/hooks.py"
        with self.assertRaises(ValueError):
            self.process("prepare")

    def test_archive_preserves_ownership(self):
        import io
        import tarfile

        captured = []

        def capture(*args, **kw):
            captured.append(kw["data"])

        with patch.object(remote, "run", capture):
            # Invoke original write function, rather than the instance test double.
            original = module("remote")
            with patch.object(original, "run", capture):
                original.write(
                    "web",
                    "tai",
                    [
                        {
                            "path": "tai/query.py",
                            "data": encoded(b"v=1"),
                            "mode": 0o640,
                            "uid": 1000,
                            "gid": 1000,
                        }
                    ],
                )
        with tarfile.open(fileobj=io.BytesIO(captured[0])) as t:
            f = t.getmembers()[0]
            self.assertEqual((f.uid, f.gid, f.mode), (1000, 1000, 0o640))
            self.assertEqual(t.extractfile(f).read(), b"v=1")


if __name__ == "__main__":
    unittest.main()

"""Security regressions for bearer enrollment and session-scoped SSH certificates."""

import concurrent.futures
import hashlib
import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import time
import types
import unittest
from unittest import mock

import test_support_console as console
import test_support_session as sessions

REMOTE = console.REMOTE
SUPPORT = sessions.SUPPORT
CONSOLE = console.CONSOLE
ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "portable_support", ROOT / "operator/tsuite_support_portable.py"
)
PORTABLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PORTABLE)


def public_key(path):
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(path)], check=True)
    return " ".join(path.with_name(path.name + ".pub").read_text().split()[:2])


class PortableClaimTest(unittest.TestCase):
    tearDown = console.SupportOperatorBrokerTest.tearDown

    def setUp(self):
        console.SupportOperatorBrokerTest.setUp(self)
        self.session_id = "012345abcdef"
        self.token = "A" * 43
        identity = REMOTE.identity_path(self.settings, self.session_id)
        identity.parent.mkdir()
        self.ca_public = public_key(identity)
        self.operator = pathlib.Path(self.temporary.name) / "operator"
        self.public = public_key(self.operator)
        self.request = {"id": self.session_id, "token": self.token, "public_key": self.public}
        self.save_grant()
        self.remote = {
            "id": self.session_id,
            "status": "issued",
            "portable_operator": True,
            "expires_at": int(time.time()) + 900,
        }

    def save_grant(self, **changes):
        state = {
            "id": self.session_id,
            "identity_file": str(REMOTE.identity_path(self.settings, self.session_id)),
            "claim_hash": hashlib.sha256(self.token.encode()).hexdigest(),
            "claim_expires_at": int(time.time()) + 900,
        }
        state.update(changes)
        REMOTE.atomic_write(REMOTE.session_state_path(self.settings, self.session_id), json.dumps(state))

    def test_real_certificate_is_bound_to_local_key_and_session(self):
        with mock.patch.object(REMOTE, "remote_session", return_value=self.remote):
            result = REMOTE.claim_operator(self.settings, self.request)
        cert = pathlib.Path(self.temporary.name) / "certificate.pub"
        cert.write_text(result["certificate"])
        detail = subprocess.run(
            ["ssh-keygen", "-L", "-f", str(cert)], capture_output=True, text=True, check=True
        ).stdout
        self.assertIn(self.session_id, detail)
        self.assertIn("permit-pty", detail)
        self.assertNotIn("permit-port-forwarding", detail)
        state = REMOTE.read_json(REMOTE.session_state_path(self.settings, self.session_id))
        self.assertNotIn("claim_hash", state)
        self.assertNotIn(self.token, json.dumps(state))
        self.assertEqual(state["claimed_public_key"], self.public)
        with mock.patch.object(REMOTE, "remote_session", return_value=self.remote):
            with self.assertRaises(REMOTE.RemoteActionError):
                REMOTE.claim_operator(self.settings, self.request)

    def test_concurrent_claim_has_exactly_one_winner(self):
        def attempt(_):
            try:
                REMOTE.claim_operator(self.settings, self.request)
                return True
            except REMOTE.RemoteActionError:
                return False

        with mock.patch.object(REMOTE, "remote_session", return_value=self.remote):
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
                self.assertEqual(sum(executor.map(attempt, range(4))), 1)

    def test_expired_wrong_token_closed_and_cross_session_grants_are_rejected(self):
        for change in (
            {"token": "B" * 43},
            {"id": "fedcba543210"},
            {"public_key": self.public + "\nssh-rsa BAD"},
        ):
            with (
                self.subTest(change=change),
                mock.patch.object(REMOTE, "remote_session", return_value=self.remote),
            ):
                with self.assertRaises(REMOTE.RemoteActionError):
                    REMOTE.claim_operator(self.settings, self.request | change)
        self.save_grant(claim_expires_at=int(time.time()) - 1)
        with self.assertRaises(REMOTE.RemoteActionError):
            REMOTE.claim_operator(self.settings, self.request)
        self.save_grant()
        for status in ("closed", "expired", "revoking"):
            with (
                self.subTest(status=status),
                mock.patch.object(REMOTE, "remote_session", return_value=self.remote | {"status": status}),
            ):
                with self.assertRaises(REMOTE.RemoteActionError):
                    REMOTE.claim_operator(self.settings, self.request)

    def test_unknown_session_does_not_create_lock_files(self):
        before = set(self.settings.state_dir.rglob("*"))
        with self.assertRaises(REMOTE.RemoteActionError):
            REMOTE.claim_operator(self.settings, self.request | {"id": "ffffffffffff"})
        self.assertEqual(before, set(self.settings.state_dir.rglob("*")))


class PortableTrustTest(unittest.TestCase):
    setUp = sessions.SupportSessionTest.setUp
    tearDown = sessions.SupportSessionTest.tearDown
    save_issued_session = sessions.SupportSessionTest.save_issued_session

    def test_native_expiry_renewal_and_revocation_preserve_bridge_keys(self):
        self.save_issued_session()
        session = self.store.load("012345abcdef")
        session["portable_operator"] = True
        self.store.save(session)
        home = pathlib.Path(self.temporary.name) / "operator-home"
        (home / ".ssh").mkdir(parents=True)
        keys = home / ".ssh/authorized_keys"
        bridge = "restrict ssh-ed25519 AAAA tsuite-support-console-bridge\n"
        keys.write_text(bridge)
        account = types.SimpleNamespace(pw_dir=str(home), pw_uid=os.getuid(), pw_gid=os.getgid())
        with mock.patch.object(SUPPORT.pwd, "getpwnam", return_value=account):
            SUPPORT.rewrite_portable_authorized_keys(self.store)
            first = keys.read_text()
            self.assertIn('principals="012345abcdef"', first)
            self.assertIn("--session-proxy 012345abcdef", first)
            session["expires_at"] += 300
            self.store.save(session)
            SUPPORT.rewrite_portable_authorized_keys(self.store)
            self.assertNotEqual(first, keys.read_text())
            self.assertEqual(keys.read_text().count("tsuite-portable:"), 1)
            session["status"] = "revoking"
            self.store.save(session)
            SUPPORT.rewrite_portable_authorized_keys(self.store)
        self.assertEqual(keys.read_text(), bridge)


class PortableConsoleTest(unittest.TestCase):
    setUp = console.SupportConsoleTest.setUp
    tearDown = console.SupportConsoleTest.tearDown
    call = console.SupportConsoleTest.call

    def test_portable_bootstrap_is_public_and_contains_no_session_secrets(self):
        app = CONSOLE.Application(self.settings)
        captured, body = self.call(app, "/operator-client")
        self.assertTrue(captured["status"].startswith("200"))
        compile(body, "<portable-bootstrap>", "exec")
        self.assertIn("CLIENT_SOURCE", body)
        self.assertNotIn("operator_claim_token", body)

    def test_authenticated_creation_shows_two_commands_with_no_manual_id_prompt(self):
        app = CONSOLE.Application(self.settings)
        session_id, csrf = app.store.new_session("alice", "Alice")
        created = {
            "id": "012345abcdef",
            "token": "legacy-token",
            "auth_mode": "enrollment-key",
            "customer_command": "customer-command",
            "operator_claim_token": "A" * 43,
        }
        body = "customer=customer-one&purpose=&csrf=" + csrf
        with mock.patch.object(CONSOLE, "manager", return_value=json.dumps(created)):
            captured, content = self.call(
                app, "/session", "POST", body, cookie="tsuite_support_session=" + session_id
            )
        self.assertTrue(captured["status"].startswith("200"))
        self.assertIn('id="customer-command"', content)
        self.assertIn('id="operator-command"', content)
        self.assertIn("012345abcdef", content)
        self.assertIn("operator-client", content)
        self.assertIn(("Cache-Control", "no-store"), captured["headers"])

    def test_claim_needs_bearer_grant_but_no_github_cookie(self):
        app = CONSOLE.Application(self.settings)
        request = json.dumps({"id": "012345abcdef", "token": "A" * 43, "public_key": "ssh-ed25519 AAAA"})
        with mock.patch.object(CONSOLE, "manager", return_value='{"certificate":"test"}') as broker:
            captured, body = self.call(app, "/operator-claim", "POST", request)
        self.assertTrue(captured["status"].startswith("200"))
        broker.assert_called_once_with("claim", input_text=request)
        self.assertIn(("Cache-Control", "no-store"), captured["headers"])
        self.assertNotIn("A" * 43, body)

    def test_claim_endpoint_rejects_oversized_and_invalid_lengths(self):
        app = CONSOLE.Application(self.settings)
        with mock.patch.object(CONSOLE, "manager") as broker:
            captured, _ = self.call(app, "/operator-claim", "POST", "x" * 8193)
        self.assertTrue(captured["status"].startswith("400"))
        broker.assert_not_called()


class PortableCleanupTest(unittest.TestCase):
    def test_edge_authentication_rejection_removes_local_credentials(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "session"
            root.mkdir()
            (root / "identity").write_text("test-key")
            settings = {"expires_at": int(time.time()) + 7200}
            with mock.patch.object(PORTABLE, "session_status", side_effect=PORTABLE.AuthorizationRevoked):
                self.assertEqual(PORTABLE.cleanup_watch(root, settings), 0)
            self.assertFalse(root.exists())

    def test_network_failure_does_not_manufacture_a_lease_extension(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "session"
            root.mkdir()
            settings = {"expires_at": int(time.time()) - 1}
            with mock.patch.object(PORTABLE, "session_status", side_effect=OSError):
                self.assertEqual(PORTABLE.cleanup_watch(root, settings), 0)
            self.assertFalse(root.exists())

"""Security regressions for bearer enrollment and session-scoped SSH certificates."""

import concurrent.futures
import base64
import html
import io
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import tempfile
import time
import types
import unittest
import urllib.parse
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

    def test_windows_bootstrap_bundles_native_client_and_relay_without_credentials(self):
        app = CONSOLE.Application(self.settings)
        captured, body = self.call(app, "/operator-client.ps1")
        self.assertTrue(captured["status"].startswith("200"))
        self.assertIn("$script:ClientSource", body)
        self.assertIn("$script:RelaySource", body)
        self.assertNotIn("operator_claim_token", body)
        self.assertNotIn("-GrantJson '", body)
        self.assertIn(("Cache-Control", "no-store"), captured["headers"])
        self.assertIn(("X-Content-Type-Options", "nosniff"), captured["headers"])

    def test_windows_operator_command_is_created_before_customer_platform_selection(self):
        app = CONSOLE.Application(self.settings)
        session_id, csrf = app.store.new_session("alice", "Alice")
        created = {"id": "012345abcdef", "token": "legacy-token", "auth_mode": "enrollment-key",
            "platform": "pending", "operator_claim_token": "A" * 43}
        body = f"customer=customer-one&operator_platform=windows&csrf={csrf}"
        with mock.patch.object(CONSOLE, "manager", return_value=json.dumps(created)) as broker:
            captured, content = self.call(app, "/session", "POST", body,
                cookie="tsuite_support_session=" + session_id)
        self.assertTrue(captured["status"].startswith("200"))
        self.assertIn("支持机执行命令（Windows PowerShell）", content)
        self.assertIn("operator-client.ps1", content)
        self.assertIn("-MaximumRedirection 0", content)
        self.assertIn("-GrantJson", content)
        self.assertIn('name="platform"', content)
        broker.assert_called_once_with("create", "customer-one", "--created-by", "alice", "--purpose", "", "--platform", "pending")

    def test_invalid_operator_platform_does_not_create_a_session(self):
        app = CONSOLE.Application(self.settings)
        session_id, csrf = app.store.new_session("alice", "Alice")
        with mock.patch.object(CONSOLE, "manager") as broker:
            captured, _ = self.call(
                app, "/session", "POST", f"customer=customer-one&operator_platform=bad&csrf={csrf}",
                cookie="tsuite_support_session=" + session_id,
            )
        self.assertTrue(captured["status"].startswith("400"))
        broker.assert_not_called()

    def test_ai_handoff_matches_all_operator_and_customer_combinations(self):
        app = CONSOLE.Application(self.settings)
        session_id, csrf = app.store.new_session("alice", "Alice")
        purpose = "检查服务 <script>alert('test')</script>"
        for operator in ("linux", "windows"):
            for platform in ("linux", "windows"):
                with self.subTest(operator=operator, customer=platform):
                    created = {"id": "012345abcdef", "token": "legacy-token", "auth_mode": "enrollment-key",
                        "platform": "pending", "operator_claim_token": "A" * 43}
                    configured = {"id": "012345abcdef", "platform": platform,
                        "customer_command": "customer-command"}
                    body = urllib.parse.urlencode({"customer": "customer-one", "operator_platform": operator,
                        "purpose": purpose, "csrf": csrf})
                    cookie = "tsuite_support_session=" + session_id
                    with mock.patch.object(CONSOLE, "manager", side_effect=[json.dumps(created), json.dumps(configured)]) as broker:
                        captured, initial = self.call(app, "/session", "POST", body, cookie)
                        self.assertTrue(captured["status"].startswith("200"))
                        self.assertIn('name="operator_platform"', initial)
                        self.assertIn('name="platform"', initial)
                        grant = json.dumps({"id": "012345abcdef", "token": "A" * 43,
                            "url": self.settings.public_url}, separators=(",", ":"))
                        selected_operator = "windows" if operator == "linux" else "linux"
                        select_body = urllib.parse.urlencode({"csrf": csrf, "customer": "customer-one",
                            "purpose": purpose, "operator_platform": selected_operator, "grant": grant, "platform": platform})
                        captured, content = self.call(app, "/session/012345abcdef/platform", "POST", select_body, cookie)
                    self.assertTrue(captured["status"].startswith("200"))
                    self.assertIn('data-copy-target="ai-instructions"', content)
                    match = re.search(r'<div id="ai-instructions" class="secret">(.*?)</div>', content, re.S)
                    self.assertIsNotNone(match)
                    prompt = html.unescape(match[1])
                    self.assertTrue(prompt.endswith("操作任务：\n" + purpose))
                    self.assertIn("A" * 43, prompt)
                    self.assertIn("在你的本机 " + ("Windows" if selected_operator == "windows" else "Linux"), prompt)
                    if selected_operator == "windows":
                        self.assertIn("operator-client.ps1", content)
                        self.assertIn("支持机执行命令（Windows PowerShell）", content)
                    else:
                        self.assertIn("python3 -c", content)
                        self.assertIn("支持机执行命令（Linux 终端）", content)
                    self.assertIn("远端命令使用 " + ("PowerShell" if platform == "windows" else "Linux Shell") + " 语法", prompt)
                    self.assertEqual(broker.call_args_list[0].args, ("create", "customer-one", "--created-by", "alice", "--purpose", purpose, "--platform", "pending"))
                    self.assertEqual(broker.call_args_list[1].args, ("set-platform", "012345abcdef", platform))
        with app.store.connection() as connection:
            self.assertNotIn("A" * 43, "\n".join(connection.iterdump()))

    def test_empty_purpose_prompts_ai_owner_to_supply_the_task(self):
        text = CONSOLE.operator_ai_instructions("customer-one", "", "012345abcdef", "linux", "linux", "connect")
        self.assertTrue(text.endswith("操作任务：\n[请补充要完成的具体任务]"))

    def test_authenticated_creation_shows_operator_command_and_defers_customer_command(self):
        app = CONSOLE.Application(self.settings)
        session_id, csrf = app.store.new_session("alice", "Alice")
        created = {"id": "012345abcdef", "token": "legacy-token", "auth_mode": "enrollment-key",
            "platform": "pending", "operator_claim_token": "A" * 43}
        body = "customer=customer-one&purpose=&csrf=" + csrf
        with mock.patch.object(CONSOLE, "manager", return_value=json.dumps(created)) as broker:
            captured, content = self.call(app, "/session", "POST", body,
                cookie="tsuite_support_session=" + session_id)
        self.assertTrue(captured["status"].startswith("200"))
        self.assertIn('id="operator-command"', content)
        self.assertNotIn('id="customer-command"', content)
        self.assertIn('name="platform"', content)
        self.assertIn('action="/support/session/012345abcdef/platform"', content)
        broker.assert_called_once_with("create", "customer-one", "--created-by", "alice", "--purpose", "", "--platform", "pending")
        self.assertIn(("Cache-Control", "no-store"), captured["headers"])

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


class PortableCommandTest(unittest.TestCase):
    def test_first_claim_can_run_a_command_without_opening_a_terminal(self):
        grant = {"id": "012345abcdef", "url": "https://edge.example.com/support", "token": "A" * 43}
        claimed = {
            "id": grant["id"], "host": "edge.example.com", "port": 22, "user": "tsuite-operator",
            "expires_at": int(time.time()) + 900, "certificate": "test certificate",
            "known_hosts": "edge.example.com ssh-ed25519 AAAA\n",
        }
        real_popen = subprocess.Popen

        def start_process(arguments, **kwargs):
            if arguments[-1] == "--watch":
                return mock.Mock()
            return real_popen(arguments, **kwargs)

        with tempfile.TemporaryDirectory() as temporary:
            stdin = io.TextIOWrapper(io.BytesIO(json.dumps(grant).encode()))
            with (
                mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": temporary}),
                mock.patch.object(PORTABLE.sys, "argv", ["support.py", "--command", "hostname"]),
                mock.patch.object(PORTABLE.sys, "stdin", stdin),
                mock.patch.object(PORTABLE, "claim", return_value=claimed),
                mock.patch.object(PORTABLE, "wait_for_customer", return_value={"platform": "linux"}),
                mock.patch.object(PORTABLE, "connect", return_value=7) as connect,
                mock.patch.object(PORTABLE.subprocess, "Popen", side_effect=start_process),
                mock.patch.object(PORTABLE, "open", side_effect=AssertionError("Opened tty"), create=True),
            ):
                self.assertEqual(PORTABLE.main(), 7)
            self.assertEqual(connect.call_args.args[-1], "hostname")
            saved = pathlib.Path(temporary) / "tsuite-support/portable/012345abcdef"
            self.assertNotIn(grant["token"], (saved / "session.json").read_text())
            stdin.close()

    def test_customer_shell_selection_encodes_windows_and_preserves_linux_commands(self):
        settings = {"id": "012345abcdef", "host": "edge.example.com", "port": 22, "user": "tsuite-operator"}
        command = "Write-Output '测试'; $env:COMPUTERNAME\n"
        relay_source = "def connect(arguments, *args, **kwargs):\n    return arguments\n"
        for platform in ("linux", "windows"):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as temporary:
                remote = {"remote_port": 22000, "customer_host_key": "ssh-ed25519 AAAA", "platform": platform}
                with mock.patch.object(PORTABLE, "ACTIVITY_SOURCE", relay_source):
                    arguments = PORTABLE.connect(pathlib.Path(temporary), settings, remote, command)
                if platform == "windows":
                    self.assertTrue(arguments[-1].startswith("powershell.exe -NoProfile -NonInteractive -EncodedCommand "))
                    self.assertEqual(base64.b64decode(arguments[-1].split()[-1]).decode("utf-16-le"), command)
                else:
                    self.assertEqual(arguments[-1], command)

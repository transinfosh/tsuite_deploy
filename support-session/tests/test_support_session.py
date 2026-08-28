import importlib.util
import json
import pathlib
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
	"tsuite_support_session", ROOT / "bastion" / "tsuite_support_session.py"
)
SUPPORT = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = SUPPORT
SPEC.loader.exec_module(SUPPORT)


PUBLIC_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"


class SupportSessionTest(unittest.TestCase):
	def setUp(self):
		self.temporary = tempfile.TemporaryDirectory()
		root = pathlib.Path(self.temporary.name)
		self.settings = SUPPORT.Settings(
			state_dir=root / "state",
			authorized_keys_dir=root / "authorized_keys",
			downloads_dir=root / "downloads",
			download_base_url="https://bastion.example.com/tsuite-support",
			bastion_host="bastion.example.com",
			bastion_port=22,
			bastion_host_key=PUBLIC_KEY,
			bootstrap_path=root / "bootstrap.sh",
			port_start=22000,
			port_end=22010,
			token_ttl_seconds=900,
			session_ttl_seconds=7200,
		)
		self.settings.bootstrap_path.write_text("#!/bin/sh\n", encoding="utf-8")
		self.store = SUPPORT.SessionStore(self.settings)

	def tearDown(self):
		self.temporary.cleanup()

	def save_issued_session(self, token="one-time-token"):
		now = int(time.time())
		session = {
			"id": "012345abcdef",
			"customer": "customer-one",
			"status": "issued",
			"created_at": now,
			"token_expires_at": now + 900,
			"expires_at": now + 7200,
			"token_hash": SUPPORT.token_hash(token),
			"remote_port": 22000,
			"tunnel_user": "tsuite-tunnel-012345ab",
			"tunnel_private_key": "PRIVATE",
			"operator_public_key": PUBLIC_KEY,
		}
		self.store.save(session)
		return token

	def test_enrollment_is_idempotent_only_for_same_nonce_and_host_key(self):
		token = self.save_issued_session()
		nonce = "abcdefghijklmnopqrstuvwxyz012345"
		first = SUPPORT.enroll(self.store, token, nonce, PUBLIC_KEY)
		second = SUPPORT.enroll(self.store, token, nonce, PUBLIC_KEY)
		self.assertEqual(first, second)
		self.assertEqual(first["tunnel_private_key"], "PRIVATE")
		with self.assertRaisesRegex(SUPPORT.SupportError, "已经被使用"):
			SUPPORT.enroll(self.store, token, "different-nonce-abcdefghijklmnopqrstuvwxyz", PUBLIC_KEY)

	def test_public_session_omits_all_credentials(self):
		self.save_issued_session()
		public = SUPPORT.public_session(self.store.load("012345abcdef"))
		self.assertNotIn("token_hash", public)
		self.assertNotIn("tunnel_private_key", public)
		self.assertNotIn("operator_public_key", public)

	def test_enrollment_key_is_forced_to_one_session_and_native_expiry(self):
		self.save_issued_session()
		session = self.store.load("012345abcdef")
		session["enrollment_private_key"] = "PRIVATE"
		session["enrollment_public_key"] = PUBLIC_KEY
		self.store.save(session)
		with mock.patch.object(SUPPORT, "chown_to_user"):
			SUPPORT.rewrite_enrollment_authorized_keys(self.store)
		authorized = (self.settings.authorized_keys_dir / "tsuite-enroll").read_text(encoding="utf-8")
		self.assertIn("enroll-ssh 012345abcdef", authorized)
		self.assertIn("restrict,expiry-time=", authorized)

	def test_customer_download_is_short_and_script_pins_host(self):
		session = {
			"download_id": "A" * 43,
			"enrollment_private_key": "SESSION ENROLLMENT KEY\n",
		}
		command = SUPPORT.customer_command(self.settings, session)
		script = SUPPORT.customer_script(
			self.settings,
			session,
		)
		self.assertEqual(
			command,
			"curl -fsS --proto '=https' --tlsv1.2 "
			"https://bastion.example.com/tsuite-support/" + "A" * 43 + " | sudo bash",
		)
		self.assertIn("StrictHostKeyChecking=yes", script)
		self.assertIn("bastion.example.com", script)
		self.assertNotIn("one-time-token", command)
		self.assertNotIn("one-time-token", script)

	def test_customer_script_file_is_not_publicly_listable_by_mode(self):
		self.settings.downloads_dir.mkdir(mode=0o750)
		session = {
			"download_id": "B" * 43,
			"enrollment_private_key": "SESSION ENROLLMENT KEY\n",
		}
		SUPPORT.write_customer_script(self.settings, session)
		path = self.settings.downloads_dir / session["download_id"]
		self.assertEqual(path.stat().st_mode & 0o777, 0o640)
		self.assertIn("StrictHostKeyChecking=yes", path.read_text(encoding="utf-8"))
		SUPPORT.remove_customer_script(self.settings, session)
		self.assertFalse(path.exists())

	def test_expired_token_is_left_for_root_gc(self):
		token = self.save_issued_session()
		session = self.store.load("012345abcdef")
		session["token_expires_at"] = int(time.time()) - 1
		self.store.save(session)
		with self.assertRaisesRegex(SUPPORT.SupportError, "会话码已过期"):
			SUPPORT.enroll(self.store, token, "abcdefghijklmnopqrstuvwxyz012345", PUBLIC_KEY)
		self.assertEqual(self.store.load("012345abcdef")["status"], "issued")

	def test_settings_reject_missing_bootstrap(self):
		value = self.settings.__dict__ | {"bootstrap_path": pathlib.Path(self.temporary.name) / "missing"}
		with self.assertRaises(SUPPORT.SupportError):
			SUPPORT.Settings(**value).validate()


class StaticSecurityTest(unittest.TestCase):
	def test_customer_token_is_not_put_in_history_or_systemd(self):
		bootstrap = (ROOT / "customer" / "bootstrap.sh").read_text(encoding="utf-8")
		self.assertIn('read -r -s -p "请输入一次性支持会话码', bootstrap)
		self.assertIn('printf \'%s\' "$TOKEN" >"$work_dir/token"', bootstrap)
		self.assertNotIn("Environment=TSUITE_SUPPORT_TOKEN", bootstrap)
		self.assertIn("OnCalendar=@$expires_at", bootstrap)

	def test_tunnel_key_and_sshd_are_loopback_only(self):
		server = (ROOT / "bastion" / "tsuite_support_session.py").read_text(encoding="utf-8")
		installer = (ROOT / "bastion" / "install.sh").read_text(encoding="utf-8")
		self.assertIn('permitlisten="127.0.0.1:', server)
		self.assertIn("GatewayPorts no", installer)
		self.assertIn("AllowTcpForwarding remote", installer)
		self.assertIn("Match User $ENROLL_USER", installer)
		self.assertIn("usermod --password 'NP'", installer)
		self.assertIn('"--password", "NP", username', server)
		self.assertIn("chown_to_user(authorized_keys_path, username)", server)
		self.assertIn('chown_to_user(temporary, "tsuite-enroll")', server)
		self.assertIn('install -d -m 0711 -o root -g root "$AUTHORIZED_KEYS_DIR"', installer)
		self.assertIn("tsuite-enroll 公钥登录自检失败", installer)
		self.assertIn('ENROLL_HOME="/var/empty/tsuite-enroll"', installer)
		self.assertIn("/tsuite-support/*", installer)
		self.assertIn('Cache-Control "no-store"', installer)
		self.assertNotIn("NOPASSWD: ALL", installer)

	def test_operator_run_preserves_remote_argument_boundaries(self):
		operator = (ROOT / "operator" / "tsuite-support").read_text(encoding="utf-8")
		self.assertIn("ssh_args.append(shlex.join(command))", operator)
		self.assertIn('if command[0] == "--":', operator)

	def test_customer_operator_account_uses_impossible_password(self):
		bootstrap = (ROOT / "customer" / "bootstrap.sh").read_text(encoding="utf-8")
		self.assertIn("useradd --create-home --shell /bin/bash --password 'NP'", bootstrap)

	def test_console_is_restricted_to_local_caddy_proxy_and_fixed_actions(self):
		installer = (ROOT / "bastion" / "install-console.sh").read_text(encoding="utf-8")
		base_installer = (ROOT / "bastion" / "install.sh").read_text(encoding="utf-8")
		self.assertIn("reverse_proxy 127.0.0.1:8765", installer)
		self.assertIn("NoNewPrivileges=yes", installer)
		self.assertIn("ProtectSystem=strict", installer)
		self.assertIn("tsuite-support-console-action create *", installer)
		self.assertIn("import $caddy_console_routes", base_installer)
		self.assertNotIn("NOPASSWD: ALL", installer)


if __name__ == "__main__":
	unittest.main()

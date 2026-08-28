import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
	"tsuite_support_console", ROOT / "console" / "tsuite_support_console.py"
)
CONSOLE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = CONSOLE
SPEC.loader.exec_module(CONSOLE)

REMOTE_SPEC = importlib.util.spec_from_file_location(
	"tsuite_support_remote_action", ROOT / "console" / "tsuite_support_remote_action.py"
)
REMOTE = importlib.util.module_from_spec(REMOTE_SPEC)
assert REMOTE_SPEC.loader is not None
sys.modules[REMOTE_SPEC.name] = REMOTE
REMOTE_SPEC.loader.exec_module(REMOTE)


class SupportConsoleTest(unittest.TestCase):
	def setUp(self):
		self.temporary = tempfile.TemporaryDirectory()
		self.settings = CONSOLE.Settings(
			client_id="Iv1.example_client_id",
			client_secret="a" * 32,
			allowed_org="transinfosh",
			allowed_team="support",
			public_url="https://edge.example.com/support",
			state_dir=pathlib.Path(self.temporary.name) / "state",
		)

	def tearDown(self):
		self.temporary.cleanup()

	def call(self, app, path, method="GET", body="", cookie=None):
		captured = {}
		environ = {
			"PATH_INFO": path,
			"REQUEST_METHOD": method,
			"QUERY_STRING": "",
			"CONTENT_LENGTH": str(len(body.encode())),
			"wsgi.input": __import__("io").BytesIO(body.encode()),
		}
		if cookie:
			environ["HTTP_COOKIE"] = cookie
		result = b"".join(app(environ, lambda status, headers: captured.update(status=status, headers=headers)))
		return captured, result.decode()

	def test_callback_url_and_pkce_challenge_are_deterministic(self):
		self.assertEqual(self.settings.callback_url, "https://edge.example.com/support/auth/github/callback")
		self.assertEqual(CONSOLE.code_challenge("abc"), "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0")

	def test_oauth_state_can_only_be_consumed_once(self):
		store = CONSOLE.Store(self.settings.state_dir)
		state, verifier = store.new_oauth_state()
		self.assertEqual(store.consume_oauth_state(state), verifier)
		self.assertIsNone(store.consume_oauth_state(state))

	def test_dashboard_requires_authenticated_cookie(self):
		app = CONSOLE.Application(self.settings)
		captured, content = self.call(app, "/")
		self.assertTrue(captured["status"].startswith("401"))
		self.assertIn("使用 GitHub 登录", content)
		self.assertIn('href="/support/login"', content)
		self.assertIn(("Cache-Control", "no-store"), captured["headers"])

	def test_dashboard_uses_the_public_support_prefix(self):
		app = CONSOLE.Application(self.settings)
		session_id, _ = app.store.new_session("alice", "Alice")
		with mock.patch.object(CONSOLE, "manager") as manager:
			captured, content = self.call(app, "/", cookie=f"tsuite_support_session={session_id}")
		self.assertTrue(captured["status"].startswith("200"))
		self.assertIn('action="/support/session"', content)
		self.assertIn('action="/support/logout"', content)
		self.assertIn('fetch("/support/sessions"', content)
		self.assertIn("正在加载会话列表", content)
		manager.assert_not_called()

	def test_dashboard_groups_customers_and_shows_full_session_ids(self):
		app = CONSOLE.Application(self.settings)
		session_id, _ = app.store.new_session("alice", "Alice")
		listing = (
			"012345abcdef\tcustomer-one\tclosed\t22000\n"
			"fedcba543210\tcustomer-one\tenrolled\t22001\n"
			"111111111111\tcustomer-two\texpired\t22002\n"
		)
		with mock.patch.object(CONSOLE, "manager", return_value=listing):
			captured, content = self.call(app, "/sessions", cookie=f"tsuite_support_session={session_id}")
		self.assertTrue(captured["status"].startswith("200"))
		self.assertIn(("Content-Type", "application/json; charset=utf-8"), captured["headers"])
		value = json.loads(content)
		content = value["summary"] + value["groups"]
		self.assertEqual(content.count('class="customer-name">customer-one'), 1)
		self.assertIn("2 次会话 · 1 个活动", content)
		self.assertIn(">012345abcdef</a>", content)
		self.assertIn(">fedcba543210</a>", content)
		self.assertIn("已连接", content)
		self.assertIn("已关闭", content)
		self.assertIn('action="/support/session/fedcba543210/close"', content)
		self.assertNotIn('action="/support/session/012345abcdef/close"', content)
		self.assertIn(".inline-actions form{margin:0 0 0 auto}", CONSOLE.page("test", "").decode())

	def test_detail_localizes_fields_values_and_destructive_action(self):
		app = CONSOLE.Application(self.settings)
		session_id, csrf = app.store.new_session("alice", "Alice")
		info = {
			"id": "012345abcdef",
			"customer": "customer-one",
			"status": "issued",
			"created_at": 1787882034,
			"remote_port": 22000,
			"tunnel_reachable": False,
		}
		with mock.patch.object(CONSOLE, "manager", return_value=json.dumps(info)):
			captured, content = self.call(
				app, "/session/012345abcdef", cookie=f"tsuite_support_session={session_id}"
			)
		self.assertTrue(captured["status"].startswith("200"))
		self.assertIn("<th>客户环境标识</th>", content)
		self.assertIn("<th>创建时间</th>", content)
		self.assertIn("2026-08-28 09:53:54（UTC+8）", content)
		self.assertIn("<th>隧道可达</th><td>否</td>", content)
		self.assertIn("等待客户", content)
		self.assertIn('class="button" href="/support/">关闭</a>', content)
		self.assertIn('class="danger">关闭会话</button>', content)
		self.assertIn('<div class="detail-actions"><a class="button"', content)
		self.assertLess(content.index(">关闭</a>"), content.index(">关闭会话</button>"))
		self.assertIn(f'name="csrf" value="{csrf}"', content)

	def test_close_route_checks_csrf_and_calls_manager(self):
		app = CONSOLE.Application(self.settings)
		session_id, csrf = app.store.new_session("alice", "Alice")
		with mock.patch.object(CONSOLE, "manager", return_value="") as manager:
			captured, _ = self.call(
				app,
				"/session/012345abcdef/close",
				"POST",
				f"csrf={csrf}",
				f"tsuite_support_session={session_id}",
			)
		self.assertTrue(captured["status"].startswith("303"))
		self.assertIn(("Location", "/support/"), captured["headers"])
		manager.assert_called_once_with("close", "012345abcdef")

	def test_create_requires_csrf_and_never_persists_one_time_token(self):
		app = CONSOLE.Application(self.settings)
		session_id, csrf = app.store.new_session("alice", "Alice")
		with mock.patch.object(CONSOLE, "manager", return_value=json.dumps({
			"id": "012345abcdef", "token": "do-not-persist", "customer_command": "curl https://example.invalid | sudo bash",
		})) as manager:
			captured, content = self.call(app, "/session", "POST", f"csrf={csrf}&customer=customer-one", f"tsuite_support_session={session_id}")
		self.assertTrue(captured["status"].startswith("200"))
		manager.assert_called_once_with("create", "customer-one")
		self.assertIn("do-not-persist", content)
		self.assertIn('data-copy-target="customer-command"', content)
		self.assertIn('data-copy-target="support-token"', content)
		self.assertIn('id="support-token" class="secret token"', content)
		self.assertIn('navigator.clipboard.writeText(target.textContent)', content)
		self.assertNotIn("#fff7ed", content)
		self.assertNotIn("#eff6ff", content)
		with app.store.connection() as connection:
			self.assertEqual(connection.execute("SELECT COUNT(*) FROM web_session").fetchone()[0], 1)
			self.assertEqual(connection.execute("SELECT COUNT(*) FROM oauth_state").fetchone()[0], 0)
		captured, content = self.call(app, "/session", "POST", "csrf=wrong&customer=customer-one", f"tsuite_support_session={session_id}")
		self.assertTrue(captured["status"].startswith("400"))
		self.assertNotIn("do-not-persist", content)

	def test_manager_bridge_is_fixed_and_not_shell_based(self):
		action = (ROOT / "bastion" / "tsuite_support_console_action.py").read_text(encoding="utf-8")
		bridge = (ROOT / "bastion" / "install-console-bridge.sh").read_text(encoding="utf-8")
		remote = (ROOT / "console" / "tsuite_support_remote_action.py").read_text(encoding="utf-8")
		self.assertIn('"--operator-public-key", str(key)', action)
		self.assertIn("CUSTOMER_RE", action)
		self.assertIn("SESSION_RE", action)
		self.assertNotIn("shell=True", action)
		self.assertIn('"StrictHostKeyChecking=yes"', remote)
		self.assertIn('"ClearAllForwardings=yes"', remote)
		self.assertIn('"ControlMaster=auto"', remote)
		self.assertIn('"ControlPersist=3600"', remote)
		self.assertIn('CONTROL_PATH = "/var/lib/tsuite-support-console/ssh-control-%C"', remote)
		self.assertIn('sudoers_file="/etc/sudoers.d/tsuite-support-session"', bridge)
		self.assertNotIn('sudoers_file="/etc/sudoers.d/tsuite-support-console-bridge"', bridge)
		self.assertNotIn("shell=True", remote)

	def test_remote_action_rejects_untrusted_identifiers_before_ssh(self):
		with self.assertRaises(SystemExit):
			REMOTE.parser().parse_args(["create", "customer;uname"])
		with self.assertRaises(SystemExit):
			REMOTE.parser().parse_args(["show", "../../etc/passwd"])


if __name__ == "__main__":
	unittest.main()

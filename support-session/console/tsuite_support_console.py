#!/usr/bin/env python3
"""GitHub-authenticated management console for temporary TSuite support sessions."""

from __future__ import annotations

import base64
import contextlib
import hashlib
import hmac
import html
import json
import os
import pathlib
import secrets
import shlex
import sqlite3
import subprocess
import sys
import struct
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from typing import Any, Callable, Iterable
from wsgiref.simple_server import WSGIRequestHandler, make_server


MAX_BODY_BYTES = 8192
SESSION_TTL_SECONDS = 8 * 60 * 60
OAUTH_STATE_TTL_SECONDS = 10 * 60
LOCAL_LOGIN_TTL_SECONDS = 5 * 60
LOCAL_INVITE_TTL_SECONDS = 30 * 60
ACTION = "/usr/local/bin/tsuite-support-console-action"
BROKER_USER = "tsuite-support-operator"
ACTIVE_STATUSES = {"issued", "enrolled", "revoking"}
CLOSABLE_STATUSES = {"issued", "enrolled"}
STATUS_PRESENTATION = {
	"issued": ("等待客户", "pending"),
	"enrolled": ("已连接", "active"),
	"revoking": ("正在关闭", "pending"),
	"closed": ("已关闭", "neutral"),
	"expired": ("已过期", "expired"),
}
DETAIL_FIELD_LABELS = {
	"id": "会话 ID",
	"customer": "客户环境标识",
	"created_by": "创建人",
	"purpose": "支持用途",
	"closed_by": "关闭人",
	"close_mode": "关闭方式",
	"close_reason": "关闭原因",
	"status": "状态",
	"created_at": "创建时间",
	"token_expires_at": "接入链接到期时间",
	"expires_at": "当前会话到期时间",
	"idle_timeout_seconds": "闲置超时（秒）",
	"last_activity_at": "最近活动时间",
	"enrolled_at": "客户接入时间",
	"revoking_at": "开始关闭时间",
	"closed_at": "关闭时间",
	"expired_at": "过期时间",
	"remote_port": "回环端口",
	"tunnel_user": "隧道用户",
	"tunnel_reachable": "隧道可达",
	"customer_host_key": "客户 SSH Host Key",
	"platform": "操作系统",
}
DETAIL_FIELD_ORDER = tuple(DETAIL_FIELD_LABELS)
TIMESTAMP_FIELDS = {key for key in DETAIL_FIELD_LABELS if key.endswith("_at")}
CHINA_TIMEZONE = timezone(timedelta(hours=8))
CLOSE_MODE_LABELS = {"normal": "正常关闭", "force": "强制关闭", "expiry": "到期回收"}


class ConsoleError(RuntimeError):
	pass


@dataclass(frozen=True)
class Settings:
	client_id: str
	client_secret: str
	allowed_org: str
	allowed_team: str | None
	public_url: str
	state_dir: pathlib.Path
	listen_host: str = "127.0.0.1"
	listen_port: int = 8765
	local_admin_user: str | None = None
	local_password_hash: str | None = None
	local_totp_secret: str | None = None

	@classmethod
	def load(cls, path: pathlib.Path) -> "Settings":
		with path.open(encoding="utf-8") as handle:
			value = json.load(handle)
		if not isinstance(value, dict):
			raise ConsoleError("控制台配置必须是 JSON 对象")
		settings = cls(
			client_id=str(value["github_client_id"]),
			client_secret=str(value["github_client_secret"]),
			allowed_org=str(value["github_allowed_org"]),
			allowed_team=(str(value["github_allowed_team"]) if value.get("github_allowed_team") else None),
			public_url=str(value["public_url"]).rstrip("/"),
			state_dir=pathlib.Path(value["state_dir"]),
			listen_host=str(value.get("listen_host", "127.0.0.1")),
			listen_port=int(value.get("listen_port", 8765)),
			local_admin_user=(str(value["local_admin_user"]) if value.get("local_admin_user") else None),
			local_password_hash=(str(value["local_password_hash"]) if value.get("local_password_hash") else None),
			local_totp_secret=(str(value["local_totp_secret"]) if value.get("local_totp_secret") else None),
		)
		settings.validate()
		return settings

	def validate(self) -> None:
		parsed = urllib.parse.urlsplit(self.public_url)
		if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment:
			raise ConsoleError("public_url 必须是不带参数的 HTTPS 地址")
		if not self.client_id or not self.client_secret:
			raise ConsoleError("GitHub OAuth Client ID/Secret 不能为空")
		if not self.allowed_org or "/" in self.allowed_org:
			raise ConsoleError("GitHub 组织名无效")
		if self.allowed_team and "/" in self.allowed_team:
			raise ConsoleError("GitHub 团队 slug 无效")
		if not 1 <= self.listen_port <= 65535:
			raise ConsoleError("监听端口无效")
		local_values = (self.local_admin_user, self.local_password_hash, self.local_totp_secret)
		if any(local_values) and not all(local_values):
			raise ConsoleError("本地管理员认证配置不完整")
		if self.local_admin_user and not self.local_admin_user.replace("-", "").replace("_", "").isalnum():
			raise ConsoleError("本地管理员用户名无效")
		if self.local_password_hash and not self.local_password_hash.startswith("scrypt$"):
			raise ConsoleError("本地管理员密码哈希无效")
		if self.local_totp_secret:
			try:
				base64.b32decode(self.local_totp_secret.upper() + "=" * (-len(self.local_totp_secret) % 8), casefold=True)
			except (ValueError, base64.binascii.Error) as error:
				raise ConsoleError("本地管理员 TOTP 密钥无效") from error

	@property
	def callback_url(self) -> str:
		return f"{self.public_url}/auth/github/callback"


class Store:
	def __init__(self, state_dir: pathlib.Path):
		self.path = state_dir / "console.sqlite3"
		state_dir.mkdir(parents=True, exist_ok=True)
		with self.connection() as connection:
			connection.executescript(
				"""
				CREATE TABLE IF NOT EXISTS oauth_state (
					state TEXT PRIMARY KEY,
					verifier TEXT NOT NULL,
					created_at INTEGER NOT NULL
				);
				CREATE TABLE IF NOT EXISTS web_session (
					id TEXT PRIMARY KEY,
					login TEXT NOT NULL,
					name TEXT NOT NULL,
					csrf TEXT NOT NULL,
					expires_at INTEGER NOT NULL
				);
				CREATE TABLE IF NOT EXISTS local_login_challenge (
					id TEXT PRIMARY KEY,
					login TEXT NOT NULL,
					attempts INTEGER NOT NULL DEFAULT 0,
					created_at INTEGER NOT NULL
				);
				CREATE TABLE IF NOT EXISTS local_user (
					username TEXT PRIMARY KEY,
					display_name TEXT NOT NULL,
					password_hash TEXT NOT NULL,
					totp_secret TEXT NOT NULL,
					is_admin INTEGER NOT NULL DEFAULT 0,
					enabled INTEGER NOT NULL DEFAULT 1,
					created_by TEXT NOT NULL,
					created_at INTEGER NOT NULL
				);
				CREATE TABLE IF NOT EXISTS local_user_invite (
					token_hash TEXT PRIMARY KEY,
					username TEXT NOT NULL,
					display_name TEXT NOT NULL,
					is_admin INTEGER NOT NULL DEFAULT 0,
					created_by TEXT NOT NULL,
					expires_at INTEGER NOT NULL,
					password_hash TEXT,
					totp_secret TEXT,
					attempts INTEGER NOT NULL DEFAULT 0
				);
				"""
			)
			columns = {row[1] for row in connection.execute("PRAGMA table_info(web_session)")}
			if "is_admin" not in columns:
				connection.execute("ALTER TABLE web_session ADD COLUMN is_admin INTEGER NOT NULL DEFAULT 0")
			if "auth_provider" not in columns:
				connection.execute("ALTER TABLE web_session ADD COLUMN auth_provider TEXT NOT NULL DEFAULT 'github'")

	def connect(self) -> sqlite3.Connection:
		connection = sqlite3.connect(self.path)
		connection.row_factory = sqlite3.Row
		return connection

	@contextlib.contextmanager
	def connection(self):
		connection = self.connect()
		try:
			with connection:
				yield connection
		finally:
			connection.close()

	def cleanup(self) -> None:
		now = int(time.time())
		with self.connection() as connection:
			connection.execute("DELETE FROM oauth_state WHERE created_at < ?", (now - OAUTH_STATE_TTL_SECONDS,))
			connection.execute("DELETE FROM web_session WHERE expires_at < ?", (now,))
			connection.execute("DELETE FROM local_login_challenge WHERE created_at < ?", (now - LOCAL_LOGIN_TTL_SECONDS,))
			connection.execute("DELETE FROM local_user_invite WHERE expires_at < ?", (now,))

	def ensure_bootstrap_admin(self, settings: Settings) -> None:
		if not (settings.local_admin_user and settings.local_password_hash and settings.local_totp_secret):
			return
		with self.connection() as connection:
			connection.execute(
				"INSERT OR IGNORE INTO local_user(username, display_name, password_hash, totp_secret, is_admin, enabled, created_by, created_at) "
				"VALUES (?, ?, ?, ?, 1, 1, 'bootstrap', ?)",
				(settings.local_admin_user, settings.local_admin_user, settings.local_password_hash, settings.local_totp_secret, int(time.time())),
			)

	def local_user(self, username: str) -> sqlite3.Row | None:
		with self.connection() as connection:
			return connection.execute("SELECT * FROM local_user WHERE username = ?", (username,)).fetchone()

	def local_users(self) -> list[sqlite3.Row]:
		with self.connection() as connection:
			return connection.execute("SELECT username, display_name, is_admin, enabled, created_by, created_at FROM local_user ORDER BY username").fetchall()

	def set_local_user_enabled(self, username: str, enabled: bool) -> None:
		with self.connection() as connection:
			connection.execute("UPDATE local_user SET enabled = ? WHERE username = ?", (int(enabled), username))
			if not enabled:
				connection.execute("DELETE FROM web_session WHERE login = ? AND auth_provider = 'local'", (username,))

	def new_local_user_invite(self, username: str, display_name: str, is_admin: bool, created_by: str) -> str:
		token = secrets.token_urlsafe(32)
		token_hash = hashlib.sha256(token.encode()).hexdigest()
		with self.connection() as connection:
			connection.execute("DELETE FROM local_user_invite WHERE username = ?", (username,))
			connection.execute(
				"INSERT INTO local_user_invite(token_hash, username, display_name, is_admin, created_by, expires_at) VALUES (?, ?, ?, ?, ?, ?)",
				(token_hash, username, display_name, int(is_admin), created_by, int(time.time()) + LOCAL_INVITE_TTL_SECONDS),
			)
		return token

	def new_local_user_totp_reset(self, username: str, created_by: str) -> str:
		user = self.local_user(username)
		if user is None:
			raise ConsoleError("用户不存在")
		token = secrets.token_urlsafe(32)
		token_hash = hashlib.sha256(token.encode()).hexdigest()
		with self.connection() as connection:
			connection.execute("DELETE FROM local_user_invite WHERE username = ?", (username,))
			connection.execute(
				"INSERT INTO local_user_invite(token_hash, username, display_name, is_admin, created_by, expires_at, password_hash, totp_secret) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
				(token_hash, username, user["display_name"], user["is_admin"], created_by, int(time.time()) + LOCAL_INVITE_TTL_SECONDS, user["password_hash"], new_totp_secret()),
			)
		return token

	def local_user_invite(self, token: str) -> sqlite3.Row | None:
		token_hash = hashlib.sha256(token.encode()).hexdigest()
		with self.connection() as connection:
			return connection.execute(
				"SELECT * FROM local_user_invite WHERE token_hash = ? AND expires_at > ? AND attempts < 5",
				(token_hash, int(time.time())),
			).fetchone()

	def prepare_local_user_invite(self, token: str, password_hash: str, totp_secret: str) -> None:
		token_hash = hashlib.sha256(token.encode()).hexdigest()
		with self.connection() as connection:
			connection.execute("UPDATE local_user_invite SET password_hash = ?, totp_secret = ? WHERE token_hash = ?", (password_hash, totp_secret, token_hash))

	def fail_local_user_invite(self, token: str) -> None:
		with self.connection() as connection:
			connection.execute("UPDATE local_user_invite SET attempts = attempts + 1 WHERE token_hash = ?", (hashlib.sha256(token.encode()).hexdigest(),))

	def activate_local_user_invite(self, token: str) -> None:
		token_hash = hashlib.sha256(token.encode()).hexdigest()
		with self.connection() as connection:
			invite = connection.execute("SELECT * FROM local_user_invite WHERE token_hash = ?", (token_hash,)).fetchone()
			if invite is None or not invite["password_hash"] or not invite["totp_secret"]:
				raise ConsoleError("邀请状态无效")
			connection.execute(
				"INSERT INTO local_user(username, display_name, password_hash, totp_secret, is_admin, enabled, created_by, created_at) VALUES (?, ?, ?, ?, ?, 1, ?, ?) "
				"ON CONFLICT(username) DO UPDATE SET totp_secret = excluded.totp_secret, enabled = 1",
				(invite["username"], invite["display_name"], invite["password_hash"], invite["totp_secret"], invite["is_admin"], invite["created_by"], int(time.time())),
			)
			connection.execute("DELETE FROM web_session WHERE login = ? AND auth_provider = 'local'", (invite["username"],))
			connection.execute("DELETE FROM local_user_invite WHERE token_hash = ?", (token_hash,))

	def new_local_login_challenge(self, login: str) -> str:
		challenge_id = secrets.token_urlsafe(32)
		with self.connection() as connection:
			connection.execute(
				"INSERT INTO local_login_challenge(id, login, created_at) VALUES (?, ?, ?)",
				(challenge_id, login, int(time.time())),
			)
		return challenge_id

	def local_login_challenge(self, challenge_id: str | None) -> sqlite3.Row | None:
		if not challenge_id:
			return None
		with self.connection() as connection:
			return connection.execute(
				"SELECT login, attempts, created_at FROM local_login_challenge "
				"WHERE id = ? AND created_at >= ? AND attempts < 5",
				(challenge_id, int(time.time()) - LOCAL_LOGIN_TTL_SECONDS),
			).fetchone()

	def fail_local_login_challenge(self, challenge_id: str) -> None:
		with self.connection() as connection:
			connection.execute("UPDATE local_login_challenge SET attempts = attempts + 1 WHERE id = ?", (challenge_id,))

	def consume_local_login_challenge(self, challenge_id: str) -> None:
		with self.connection() as connection:
			connection.execute("DELETE FROM local_login_challenge WHERE id = ?", (challenge_id,))

	def new_oauth_state(self) -> tuple[str, str]:
		state, verifier = secrets.token_urlsafe(32), secrets.token_urlsafe(64)
		with self.connection() as connection:
			connection.execute(
				"INSERT INTO oauth_state(state, verifier, created_at) VALUES (?, ?, ?)",
				(state, verifier, int(time.time())),
			)
		return state, verifier

	def consume_oauth_state(self, state: str) -> str | None:
		with self.connection() as connection:
			row = connection.execute("SELECT verifier, created_at FROM oauth_state WHERE state = ?", (state,)).fetchone()
			connection.execute("DELETE FROM oauth_state WHERE state = ?", (state,))
		if row is None or int(row["created_at"]) < int(time.time()) - OAUTH_STATE_TTL_SECONDS:
			return None
		return str(row["verifier"])

	def new_session(self, login: str, name: str, is_admin: bool = False, auth_provider: str = "github") -> tuple[str, str]:
		session_id, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
		with self.connection() as connection:
			connection.execute(
				"INSERT INTO web_session(id, login, name, csrf, expires_at, is_admin, auth_provider) VALUES (?, ?, ?, ?, ?, ?, ?)",
				(session_id, login, name, csrf, int(time.time()) + SESSION_TTL_SECONDS, int(is_admin), auth_provider),
			)
		return session_id, csrf

	def session(self, session_id: str | None) -> sqlite3.Row | None:
		if not session_id:
			return None
		with self.connection() as connection:
			return connection.execute(
				"SELECT login, name, csrf, expires_at, is_admin, auth_provider FROM web_session WHERE id = ? AND expires_at > ?",
				(session_id, int(time.time())),
			).fetchone()

	def delete_session(self, session_id: str | None) -> None:
		if session_id:
			with self.connection() as connection:
				connection.execute("DELETE FROM web_session WHERE id = ?", (session_id,))


def code_challenge(verifier: str) -> str:
	digest = hashlib.sha256(verifier.encode()).digest()
	return base64.urlsafe_b64encode(digest).rstrip(b"=").decode()


def github_json(request: urllib.request.Request, body: dict[str, str] | None = None) -> dict[str, Any]:
	if body is not None:
		request.data = urllib.parse.urlencode(body).encode()
		request.add_header("Content-Type", "application/x-www-form-urlencoded")
	request.add_header("Accept", "application/json")
	request.add_header("User-Agent", "tsuite-support-console")
	try:
		with urllib.request.urlopen(request, timeout=10) as response:
			value = json.loads(response.read().decode())
	except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as error:
		raise ConsoleError("GitHub 服务暂时不可用") from error
	if not isinstance(value, dict):
		raise ConsoleError("GitHub 返回无效数据")
	return value


def github_identity(settings: Settings, code: str, verifier: str) -> tuple[str, str]:
	token_response = github_json(
		urllib.request.Request("https://github.com/login/oauth/access_token", method="POST"),
		{
			"client_id": settings.client_id,
			"client_secret": settings.client_secret,
			"code": code,
			"redirect_uri": settings.callback_url,
			"code_verifier": verifier,
		},
	)
	token = token_response.get("access_token")
	if not isinstance(token, str) or not token:
		raise ConsoleError("GitHub 登录未返回访问令牌")
	headers = {"Authorization": f"Bearer {token}", "X-GitHub-Api-Version": "2022-11-28"}
	user = github_json(urllib.request.Request("https://api.github.com/user", headers=headers))
	login = user.get("login")
	if not isinstance(login, str) or not login:
		raise ConsoleError("GitHub 账户信息无效")
	membership = github_json(
		urllib.request.Request(
			f"https://api.github.com/user/memberships/orgs/{urllib.parse.quote(settings.allowed_org, safe='')}",
			headers=headers,
		)
	)
	if membership.get("state") != "active":
		raise ConsoleError("该 GitHub 账户不在允许的组织中")
	if settings.allowed_team:
		team = github_json(
			urllib.request.Request(
				"https://api.github.com/orgs/"
				f"{urllib.parse.quote(settings.allowed_org, safe='')}/teams/"
				f"{urllib.parse.quote(settings.allowed_team, safe='')}/memberships/{urllib.parse.quote(login, safe='')}",
				headers=headers,
			)
		)
		if team.get("state") != "active":
			raise ConsoleError("该 GitHub 账户不在允许的团队中")
	name = user.get("name") if isinstance(user.get("name"), str) else login
	return login, name


def verify_password(password: str, encoded: str) -> bool:
	try:
		_, salt_hex, digest_hex = encoded.split("$", 2)
		digest = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt_hex), n=2**14, r=8, p=1, dklen=32)
		return hmac.compare_digest(digest.hex(), digest_hex)
	except (ValueError, TypeError):
		return False


def hash_password(password: str) -> str:
	salt = os.urandom(16)
	digest = hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=1, dklen=32)
	return f"scrypt${salt.hex()}${digest.hex()}"


def new_totp_secret() -> str:
	return base64.b32encode(os.urandom(20)).decode().rstrip("=")


def verify_totp(secret: str, code: str, now: int | None = None) -> bool:
	if not code.isdigit() or len(code) != 6:
		return False
	key = base64.b32decode(secret.upper() + "=" * (-len(secret) % 8), casefold=True)
	timestep = int(time.time() if now is None else now) // 30
	for counter in (timestep - 1, timestep, timestep + 1):
		mac = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
		offset = mac[-1] & 15
		value = (struct.unpack(">I", mac[offset:offset + 4])[0] & 0x7fffffff) % 1000000
		if hmac.compare_digest(f"{value:06d}", code):
			return True
	return False


def totp_qr_data_uri(uri: str) -> str:
	try:
		result = subprocess.run(
			["qrencode", "-t", "SVG", "-o", "-", "-m", "2", "-s", "5", "-l", "M"],
			input=uri.encode(), capture_output=True, timeout=5, check=False,
		)
	except (OSError, subprocess.TimeoutExpired) as error:
		raise ConsoleError("动态验证码二维码生成失败") from error
	if result.returncode or not result.stdout.startswith(b"<?xml") or len(result.stdout) > 200_000:
		raise ConsoleError("动态验证码二维码生成失败")
	return "data:image/svg+xml;base64," + base64.b64encode(result.stdout).decode()


def manager(*arguments: str, input_text: str | None = None) -> str:
	try:
		result = subprocess.run(
				["sudo", "-n", "-u", BROKER_USER, ACTION, *arguments],
			check=False, capture_output=True, text=True, timeout=30, input=input_text,
		)
	except (OSError, subprocess.TimeoutExpired) as error:
		raise ConsoleError("支持会话服务暂时不可用") from error
	if result.returncode:
		raise ConsoleError("支持会话操作失败，请稍后重试或查看堡垒机服务日志")
	return result.stdout


def parse_cookie(header: str | None, name: str) -> str | None:
	if not header:
		return None
	for item in header.split(";"):
		key, separator, value = item.strip().partition("=")
		if separator and key == name:
			return value
	return None


def form_data(environ: dict[str, Any]) -> dict[str, str]:
	try:
		length = int(environ.get("CONTENT_LENGTH") or "0")
	except ValueError as error:
		raise ConsoleError("无效请求") from error
	if length < 0 or length > MAX_BODY_BYTES:
		raise ConsoleError("请求过大")
	body = environ["wsgi.input"].read(length).decode("utf-8")
	return {key: values[-1] for key, values in urllib.parse.parse_qs(body, keep_blank_values=True).items()}


def detail_value(field: str, value: Any) -> str:
	if field in TIMESTAMP_FIELDS and isinstance(value, (int, float)):
		return datetime.fromtimestamp(value, CHINA_TIMEZONE).strftime("%Y-%m-%d %H:%M:%S（UTC+8）")
	if isinstance(value, bool):
		return "是" if value else "否"
	if field == "close_mode":
		return CLOSE_MODE_LABELS.get(str(value), str(value))
	return str(value)


def status_badge(status: str) -> str:
	label, style = STATUS_PRESENTATION.get(status, (status, "neutral"))
	return f'<span class="badge badge-{style}">{html.escape(label)}</span>'


def login_layout(content: str) -> str:
	return """<style>
.login-shell{min-height:calc(100svh - 100px);display:flex;flex-direction:column;align-items:center;justify-content:center;padding:32px 0;gap:22px}
.login-card{width:min(420px,100%);padding:38px 40px;background:#fff;border:1px solid #dbe2ea;border-radius:20px;box-shadow:0 18px 50px -28px rgb(15 23 42 / 28%)}
.login-brand{display:flex;align-items:center;justify-content:center;gap:10px;margin-bottom:28px;color:#334155;font-size:17px;font-weight:700}
.login-mark{display:grid;place-items:center;width:36px;height:36px;border-radius:10px;color:#fff;background:#0369a1;font-size:14px}
.login-card h1{margin:0;text-align:center;font-size:27px;line-height:1.3;letter-spacing:-.035em}
.login-description{margin:12px 0 28px;text-align:center;color:#64748b;line-height:1.7;font-size:14px}
.login-form{display:grid;gap:17px}.login-form label{display:grid;gap:7px;color:#334155;font-size:13px;font-weight:650}.login-form input{width:100%;min-width:0;height:46px;border-radius:9px}.login-form button{min-height:46px;margin-top:3px;border-radius:9px;font-size:14px;font-weight:650}
.login-error{margin:0 0 16px;padding:10px 12px;border-radius:8px;color:#991b1b;background:#fef2f2;font-size:13px;line-height:1.55}
.login-card .secret{padding:13px;border:1px solid #dbe2ea;border-radius:9px;background:#f8fafc;font:600 14px ui-monospace,SFMono-Regular,Menlo,monospace;overflow-wrap:anywhere}
.totp-qr{display:grid;place-items:center;width:220px;height:220px;margin:0 auto 14px;padding:10px;border:1px solid #dbe2ea;border-radius:14px;background:#fff}.totp-qr img{display:block;width:100%;height:100%}.totp-fallback{margin:12px 0 18px}.totp-fallback summary{cursor:pointer;text-align:center;color:#64748b;font-size:13px}.totp-fallback .secret{margin-top:12px;text-align:center;letter-spacing:.08em}.totp-fallback p{margin:12px 0 0;text-align:center}
.login-divider{display:flex;align-items:center;gap:12px;margin:24px 0 16px;color:#94a3b8;font-size:12px}.login-divider::before,.login-divider::after{content:"";height:1px;flex:1;background:#e2e8f0}
.social-login{display:flex;justify-content:center}.github-login{display:grid;place-items:center;width:44px;height:44px;border:1px solid #d5dce5;border-radius:50%;color:#17212b;background:#fff;transition:border-color .15s,box-shadow .15s,transform .15s}.github-login:hover{border-color:#94a3b8;box-shadow:0 5px 14px rgb(15 23 42 / 10%);transform:translateY(-1px)}.github-login:focus-visible{outline:3px solid #bae6fd;outline-offset:3px}.github-login svg{width:22px;height:22px;fill:currentColor}
.login-note{margin:18px 0 0;text-align:center;color:#94a3b8;font-size:12px;line-height:1.65}.login-footer{margin:0;color:#64748b;font-size:12px;letter-spacing:.03em}.login-back{display:block;margin-top:18px;text-align:center;font-size:13px}
.otp-input{text-align:center;font:600 22px ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.28em;padding-left:calc(12px + .28em)}
@media(max-width:480px){.login-shell{min-height:calc(100svh - 48px);padding:20px 0;width:100%}.login-card{padding:32px 24px}.login-card h1{font-size:25px}}
@media(prefers-reduced-motion:reduce){.github-login{transition:none}}
</style><main class="login-shell"><section class="login-card">{content}</section><p class="login-footer">TSuite · 远程支持工作台</p></main>""".replace("{content}", content)


def login_content(local_enabled: bool = False, error: str = "") -> str:
	local_login = ""
	if local_enabled:
		error_html = f'<p class="login-error" role="alert">{html.escape(error)}</p>' if error else ""
		local_login = error_html + """<form class="login-form" method="post" action="/support/login/local">
<label>账号<input name="username" required autofocus autocomplete="username"></label>
<label>密码<input name="password" type="password" required autocomplete="current-password"></label>
<button class="primary">继续</button></form>"""
	content = """<div class="login-brand"><span class="login-mark" aria-hidden="true">TS</span><span>TSuite</span></div>
<h1 id="login-title">远程支持会话</h1>
<p class="login-description">登录支持工作台，安全地创建和管理临时远程会话。</p>
{local_login}<div class="login-divider"><span>其他登录方式</span></div>
<div class="social-login"><a class="github-login" href="/support/login" aria-label="使用 GitHub 登录" title="使用 GitHub 登录"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 .5C5.37.5 0 5.87 0 12.5c0 5.3 3.438 9.8 8.205 11.385.6.11.82-.26.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.043-1.61-4.043-1.61-.546-1.387-1.333-1.756-1.333-1.756-1.09-.745.083-.73.083-.73 1.205.085 1.84 1.237 1.84 1.237 1.07 1.835 2.807 1.305 3.492.998.108-.776.418-1.305.76-1.605-2.665-.305-5.467-1.333-5.467-5.93 0-1.31.467-2.382 1.235-3.222-.124-.303-.535-1.523.117-3.176 0 0 1.008-.322 3.3 1.23A11.5 11.5 0 0 1 12 6.3c1.02.005 2.047.138 3.006.404 2.29-1.552 3.296-1.23 3.296-1.23.654 1.653.243 2.873.12 3.176.77.84 1.233 1.912 1.233 3.222 0 4.61-2.807 5.622-5.48 5.92.43.37.814 1.102.814 2.222 0 1.606-.015 2.896-.015 3.29 0 .32.216.694.825.576C20.565 22.296 24 17.797 24 12.5 24 5.87 18.627.5 12 .5Z"/></svg></a></div>
<p class="login-note">GitHub 登录仅作为备用方式</p>""".replace("{local_login}", local_login)
	return login_layout(content)


def totp_content(error: str = "") -> str:
	error_html = f'<p class="login-error" role="alert">{html.escape(error)}</p>' if error else ""
	content = """<div class="login-brand"><span class="login-mark" aria-hidden="true">TS</span><span>TSuite</span></div>
<h1 id="login-title">验证身份</h1><p class="login-description">账号密码已通过，请输入验证器中显示的 6 位动态验证码。</p>
{error}<form class="login-form" method="post" action="/support/login/local/totp"><label>动态验证码<input class="otp-input" name="totp" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" required autofocus autocomplete="one-time-code"></label><button class="primary">确认登录</button></form>
<a class="login-back" href="/support/">返回重新登录</a>""".replace("{error}", error_html)
	return login_layout(content)


def invite_password_content(token: str, username: str, error: str = "") -> str:
	error_html = f'<p class="login-error" role="alert">{html.escape(error)}</p>' if error else ""
	content = f"""<div class="login-brand"><span class="login-mark" aria-hidden="true">TS</span><span>TSuite</span></div>
<h1>设置本地账号</h1><p class="login-description">为 <strong>{html.escape(username)}</strong> 设置登录密码，下一步绑定动态验证码。</p>
{error_html}<form class="login-form" method="post" action="/support/invite/password">
<input type="hidden" name="token" value="{html.escape(token)}">
<label>密码<input name="password" type="password" minlength="16" required autocomplete="new-password"></label>
<label>确认密码<input name="confirm_password" type="password" minlength="16" required autocomplete="new-password"></label>
<button class="primary">继续绑定验证器</button></form>"""
	return login_layout(content)


def invite_totp_content(token: str, username: str, secret: str, error: str = "") -> str:
	error_html = f'<p class="login-error" role="alert">{html.escape(error)}</p>' if error else ""
	uri = "otpauth://totp/" + urllib.parse.quote(f"TSuite:{username}") + "?" + urllib.parse.urlencode({"secret": secret, "issuer": "TSuite"})
	qr_data_uri = totp_qr_data_uri(uri)
	content = f"""<div class="login-brand"><span class="login-mark" aria-hidden="true">TS</span><span>TSuite</span></div>
<h1>绑定动态验证码</h1><p class="login-description">使用验证器 App 扫描二维码，然后输入当前显示的 6 位验证码完成绑定。</p>
{error_html}<div class="totp-qr"><img src="{qr_data_uri}" alt="TSuite 动态验证码绑定二维码" width="200" height="200"></div>
<details class="totp-fallback"><summary>无法扫码？使用其他绑定方式</summary><div class="secret">{html.escape(secret)}</div>
<p><a class="button" href="{html.escape(uri)}">在本机验证器中打开</a></p></details>
<form class="login-form" method="post" action="/support/invite/totp"><input type="hidden" name="token" value="{html.escape(token)}">
<label>动态验证码<input class="otp-input" name="totp" inputmode="numeric" pattern="[0-9]{{6}}" maxlength="6" required autofocus autocomplete="one-time-code"></label>
<button class="primary">完成绑定</button></form>"""
	return login_layout(content)


def page(title: str, content: str) -> bytes:
	return f"""<!doctype html>
<html lang=\"zh-CN\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
<title>{html.escape(title)} · TSuite Support</title>
<style>
*{{box-sizing:border-box}} body{{max-width:1080px;margin:0 auto;padding:36px 24px 64px;color:#17212b;font:15px system-ui,-apple-system,\"Segoe UI\",sans-serif;background:#f5f7fa}}
header{{display:flex;justify-content:space-between;align-items:center;padding:0 0 24px}} h1{{margin:0;font-size:26px;letter-spacing:-.02em}} h2,h3{{margin-top:0}} h2{{font-size:19px}} h3{{font-size:17px}}
a{{color:#075985;text-decoration:none}} a:hover{{text-decoration:underline}} button,a.button{{display:inline-flex;align-items:center;justify-content:center;border:1px solid #cbd5e1;border-radius:7px;padding:9px 14px;color:#075985;background:#fff;cursor:pointer}} a.button:hover{{text-decoration:none}} button.primary{{border-color:#0369a1;color:#fff;background:#0369a1}} button.danger{{border-color:#dc2626;color:#fff;background:#dc2626}} button.compact{{padding:6px 10px;font-size:13px}} button:hover,a.button:hover{{filter:brightness(.97)}}
input,select{{min-width:180px;border:1px solid #cbd5e1;border-radius:7px;padding:10px 12px;background:#fff}} input:focus,select:focus{{outline:3px solid #bae6fd;border-color:#0284c7}}
.card{{background:#fff;border:1px solid #dbe2ea;border-radius:12px;padding:22px;margin:0 0 20px;box-shadow:0 1px 2px rgb(15 23 42 / 4%)}} .muted{{color:#64748b}} .error{{color:#b91c1c}} code{{border-radius:4px;padding:2px 5px;background:#eaf1f7}}
.secret-section{{margin-top:22px}} .secret-heading{{display:flex;align-items:center;justify-content:space-between;gap:16px;margin-bottom:9px}} .secret-heading h2{{margin:0}} .secret{{border:1px solid #cbd5e1;border-radius:8px;padding:14px;color:#0f172a;background:#f8fafc;font:14px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;overflow-wrap:anywhere}} .copy-button{{min-width:76px;padding:7px 11px;color:#0369a1;background:#fff}} .copy-button.copied{{border-color:#86efac;color:#166534;background:#f0fdf4}}
.create-form{{display:flex;align-items:end;gap:10px;flex-wrap:wrap}} .create-form label{{display:grid;gap:7px;font-weight:600}} .summary{{display:flex;gap:20px;margin-top:18px;color:#475569}} .summary strong{{color:#0f172a;font-size:18px}}
.group-list{{display:grid;gap:14px}} .customer-group{{overflow:hidden;border:1px solid #dbe2ea;border-radius:12px;background:#fff}} .customer-group summary{{display:flex;align-items:center;gap:12px;padding:16px 18px;cursor:pointer;list-style:none}} .customer-group summary::-webkit-details-marker{{display:none}} .customer-group summary::before{{content:\"›\";color:#64748b;font-size:22px;transform:rotate(0deg);transition:transform .15s}} .customer-group[open] summary::before{{transform:rotate(90deg)}}
.customer-name{{font-size:17px;font-weight:700}} .group-meta{{margin-left:auto;color:#64748b}} .session-table-wrap{{overflow-x:auto;border-top:1px solid #e2e8f0}} table{{border-collapse:collapse;width:100%;background:#fff}} td,th{{padding:12px 16px;border-bottom:1px solid #eef2f6;text-align:left;white-space:nowrap}} th{{color:#64748b;font-size:13px;font-weight:600;background:#f8fafc}} tr:last-child td{{border-bottom:0}} .session-id{{font:600 13px ui-monospace,SFMono-Regular,Menlo,monospace}} .inline-actions{{display:flex;align-items:center;gap:12px}} .inline-actions form{{margin:0 0 0 auto}}
.badge{{display:inline-flex;align-items:center;border-radius:999px;padding:4px 9px;font-size:12px;font-weight:650}} .badge-active{{color:#166534;background:#dcfce7}} .badge-pending{{color:#9a3412;background:#ffedd5}} .badge-neutral{{color:#475569;background:#e2e8f0}} .badge-expired{{color:#6b7280;background:#f1f5f9}}
.detail-table th{{width:36%;color:#475569}} .detail-table td{{white-space:normal;overflow-wrap:anywhere}} .detail-actions{{display:flex;align-items:center;gap:10px}} .danger-zone{{display:flex;align-items:center;justify-content:space-between;gap:20px;border-top:1px solid #e2e8f0;margin-top:20px;padding-top:20px}} .danger-zone p{{margin:0;color:#64748b}}
.empty{{padding:36px;text-align:center;color:#64748b}} .loading{{display:flex;align-items:center;justify-content:center;gap:10px;padding:36px;color:#64748b}} .loading-label{{color:#64748b}} .spinner{{width:18px;height:18px;border:2px solid #cbd5e1;border-top-color:#0284c7;border-radius:50%;animation:spin .7s linear infinite}} @keyframes spin{{to{{transform:rotate(360deg)}}}} @media (max-width:640px){{body{{padding:24px 14px}} header{{align-items:flex-start}} input{{min-width:100%;width:100%}} .create-form label{{width:100%}} .summary{{gap:12px;flex-wrap:wrap}} .group-meta{{font-size:12px}}}}
</style><body>{content}<script>
async function loadSessionData() {{
	const summary = document.getElementById("session-summary");
	const groups = document.getElementById("session-groups");
	if (!summary || !groups) return;
	groups.setAttribute("aria-busy", "true");
	try {{
		const response = await fetch("/support/sessions", {{
			credentials: "same-origin",
			headers: {{"Accept": "application/json"}},
		}});
		if (!response.ok) throw new Error("request failed");
		const value = await response.json();
		summary.innerHTML = value.summary;
		groups.innerHTML = value.groups;
		groups.setAttribute("aria-busy", "false");
	}} catch (error) {{
		summary.innerHTML = '<span class="error">会话数据加载失败</span>';
		groups.innerHTML = '<div class="card empty">暂时无法读取会话列表。 <button type="button" data-retry-sessions>重新加载</button></div>';
		groups.setAttribute("aria-busy", "false");
	}}
}}
function fallbackCopy(value) {{
	const input = document.createElement("textarea");
	input.value = value;
	input.setAttribute("readonly", "");
	input.style.position = "fixed";
	input.style.opacity = "0";
	document.body.appendChild(input);
	input.select();
	const copied = document.execCommand("copy");
	input.remove();
	if (!copied) throw new Error("copy failed");
}}
document.addEventListener("click", async (event) => {{
	if (event.target.closest("[data-retry-sessions]")) {{
		await loadSessionData();
		return;
	}}
	const button = event.target.closest("[data-copy-target]");
	if (!button) return;
	const target = document.getElementById(button.dataset.copyTarget);
	if (!target) return;
	try {{
		if (navigator.clipboard && window.isSecureContext) {{
			await navigator.clipboard.writeText(target.textContent);
		}} else {{
			fallbackCopy(target.textContent);
		}}
		button.textContent = "已复制";
		button.classList.add("copied");
	}} catch (error) {{
		button.textContent = "复制失败";
	}}
	window.setTimeout(() => {{
		button.textContent = "复制";
		button.classList.remove("copied");
	}}, 1600);
}});
document.addEventListener("DOMContentLoaded", loadSessionData);
</script></body></html>""".encode()


class Application:
	def __init__(self, settings: Settings):
		self.settings = settings
		self.store = Store(settings.state_dir)
		self.store.ensure_bootstrap_admin(settings)

	def response(self, start_response: Callable[..., Any], status: HTTPStatus, body: bytes, headers: Iterable[tuple[str, str]] = ()) -> list[bytes]:
		base = [
			("Content-Type", "text/html; charset=utf-8"), ("Content-Length", str(len(body))),
			("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"),
			("X-Frame-Options", "DENY"), ("Referrer-Policy", "no-referrer"),
		]
		start_response(f"{status.value} {status.phrase}", [*base, *headers])
		return [body]

	def json_response(self, start_response: Callable[..., Any], value: dict[str, str]) -> list[bytes]:
		body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
		headers = [
			("Content-Type", "application/json; charset=utf-8"),
			("Content-Length", str(len(body))),
			("Cache-Control", "no-store"),
			("X-Content-Type-Options", "nosniff"),
			("X-Frame-Options", "DENY"),
			("Referrer-Policy", "no-referrer"),
		]
		start_response(f"{HTTPStatus.OK.value} {HTTPStatus.OK.phrase}", headers)
		return [body]

	def redirect(self, start_response: Callable[..., Any], location: str, headers: Iterable[tuple[str, str]] = ()) -> list[bytes]:
		return self.response(start_response, HTTPStatus.SEE_OTHER, b"", [("Location", location), *headers])

	def require_session(self, environ: dict[str, Any]) -> tuple[str | None, sqlite3.Row | None]:
		session_id = parse_cookie(environ.get("HTTP_COOKIE"), "tsuite_support_session")
		return session_id, self.store.session(session_id)

	def session_fragments(self, session: sqlite3.Row) -> tuple[str, str]:
		grouped: dict[str, list[tuple[str, str, str]]] = defaultdict(list)
		for line in manager("list").splitlines():
			parts = line.split("\t")
			if len(parts) == 4:
				session_id, customer, status, port = parts
				if status in {"closed", "expired"}:
					continue
				grouped[customer].append((session_id, status, port))
		group_cards = []
		active_total = sum(
			status in ACTIVE_STATUSES
			for sessions in grouped.values()
			for _, status, _ in sessions
		)
		customers = sorted(
			grouped,
			key=lambda value: (
				not any(status in ACTIVE_STATUSES for _, status, _ in grouped[value]),
				value,
			),
		)
		for customer in customers:
			sessions = grouped[customer]
			active_count = sum(status in ACTIVE_STATUSES for _, status, _ in sessions)
			rows = []
			for support_id, status, port in sorted(
				sessions, key=lambda item: item[1] not in ACTIVE_STATUSES
			):
				escaped_id = html.escape(support_id)
				actions = [f'<a href="/support/session/{escaped_id}">查看详情</a>']
				if status in CLOSABLE_STATUSES:
					actions.append(
						f'<form method="post" action="/support/session/{escaped_id}/close" '
						'onsubmit="return confirm(\'确定关闭这个支持会话吗？系统会先调度客户侧清理，再撤销连接。\')">'
						f'<input type="hidden" name="csrf" value="{html.escape(str(session["csrf"]))}">'
						'<button type="submit" class="danger compact">关闭会话</button></form>'
					)
				rows.append(
					f'<tr><td><a class="session-id" href="/support/session/{escaped_id}">{escaped_id}</a></td>'
					f'<td>{status_badge(status)}</td>'
					f'<td><code>{html.escape(port)}</code></td>'
					f'<td><div class="inline-actions">{"".join(actions)}</div></td></tr>'
				)
			open_group = " open" if active_count else ""
			active_text = f" · {active_count} 个活动" if active_count else ""
			group_cards.append(
				f'<details class="customer-group"{open_group}><summary>'
				f'<span class="customer-name">{html.escape(customer)}</span>'
				f'<span class="group-meta">{len(sessions)} 次会话{active_text}</span></summary>'
				'<div class="session-table-wrap"><table><thead><tr>'
				'<th>会话 ID</th><th>状态</th><th>回环端口</th><th>操作</th>'
				f'</tr></thead><tbody>{"".join(rows)}</tbody></table></div></details>'
			)
		groups = "".join(group_cards) or '<div class="card empty">当前没有活动支持会话</div>'
		summary = (
			f'<span><strong>{len(grouped)}</strong> 个客户环境</span>'
			f'<span><strong>{active_total}</strong> 个活动会话</span>'
		)
		return summary, groups

	def users_page(self, start_response: Callable[..., Any], session: sqlite3.Row) -> list[bytes]:
		rows = []
		for user in self.store.local_users():
			username = html.escape(str(user["username"]))
			enabled = bool(user["enabled"])
			action = "禁用" if enabled else "启用"
			status = "已启用" if enabled else "已禁用"
			role = "管理员" if bool(user["is_admin"]) else "操作员"
			disabled = " disabled" if str(user["username"]) == str(session["login"]) else ""
			rows.append(
				f'<tr><td><strong>{username}</strong><br><span class="muted">{html.escape(str(user["display_name"]))}</span></td>'
				f'<td>{role}</td><td>{status}</td><td><div class="inline-actions"><form method="post" action="/support/users/{username}/reset-totp">'
				f'<input type="hidden" name="csrf" value="{html.escape(str(session["csrf"]))}">'
				f'<button class="compact">重绑 TOTP</button></form><form method="post" action="/support/users/{username}/toggle">'
				f'<input type="hidden" name="csrf" value="{html.escape(str(session["csrf"]))}">'
				f'<button class="compact"{disabled}>{action}</button></form></div></td></tr>'
			)
		content = f"""<header><div><h1>本地用户</h1><p class="muted">通过一次性邀请完成密码设置和 TOTP 绑定。</p></div><a class="button" href="/support/">返回工作台</a></header>
<section class="card"><h2>邀请新用户</h2><form class="create-form" method="post" action="/support/users/invite">
<input type="hidden" name="csrf" value="{html.escape(str(session['csrf']))}">
<label>用户名<input name="username" required pattern="[A-Za-z0-9_-]{{3,64}}" autocomplete="off"></label>
<label>显示名称<input name="display_name" required maxlength="80" autocomplete="off"></label>
<label>角色<select name="role"><option value="operator">操作员</option><option value="admin">管理员</option></select></label>
<button class="primary">生成邀请链接</button></form><p class="muted">邀请链接 30 分钟有效且只能使用一次。</p></section>
<section class="card"><h2>现有用户</h2><div class="session-table-wrap"><table><thead><tr><th>用户</th><th>角色</th><th>状态</th><th>操作</th></tr></thead><tbody>{''.join(rows)}</tbody></table></div></section>"""
		return self.response(start_response, HTTPStatus.OK, page("本地用户", content))

	def dashboard(self, start_response: Callable[..., Any], session: sqlite3.Row) -> list[bytes]:
		users_link = '<a class="button" href="/support/users">用户管理</a>' if bool(session["is_admin"]) else ""
		content = f"""<header><h1>TSuite 支持管理</h1><div class=\"detail-actions\">{users_link}<form method=\"post\" action=\"/support/logout\"><input type=\"hidden\" name=\"csrf\" value=\"{html.escape(str(session['csrf']))}\"><button>退出 {html.escape(str(session['login']))}</button></form></div></header>
<section class=\"card\"><h2>新建支持会话</h2><p class=\"muted\">为同一台客户机器使用固定的环境标识，例如 <code>dtaut-srm-prod-01</code>。每次连接都会自动生成新的完整会话 ID。</p>
<form class=\"create-form\" method=\"post\" action=\"/support/session\"><input type=\"hidden\" name=\"csrf\" value=\"{html.escape(str(session['csrf']))}\"><label>客户环境标识<input name=\"customer\" required autocomplete=\"off\" placeholder=\"例如 dtaut-srm-prod-01\" pattern=\"[a-z0-9][a-z0-9-]{{0,47}}\"></label><label>支持用途（可选）<input name=\"purpose\" maxlength=\"200\" autocomplete=\"off\" placeholder=\"例如升级 SRM 至 0.1.10\"></label><label>操作系统<select name=\"platform\"><option value=\"linux\">Linux</option><option value=\"windows\">Windows（Server 2016+ / Windows 10/11）</option></select></label><button class=\"primary\">创建会话</button></form>
<div id=\"session-summary\" class=\"summary\" aria-live=\"polite\"><span class=\"loading-label\">正在读取会话数据…</span></div></section>
<section><h2>客户环境与会话</h2><div id=\"session-groups\" class=\"group-list\" aria-live=\"polite\" aria-busy=\"true\"><div class=\"card loading\"><span class=\"spinner\"></span><span>正在加载会话列表…</span></div></div></section>"""
		return self.response(start_response, HTTPStatus.OK, page("支持管理", content))

	def __call__(self, environ: dict[str, Any], start_response: Callable[..., Any]) -> list[bytes]:
		self.store.cleanup()
		path = environ.get("PATH_INFO", "/")
		method = environ.get("REQUEST_METHOD", "GET")
		try:
			if path == "/operator-client" and method == "GET":
				root = pathlib.Path(__file__).resolve().parent
				if not (root / "tsuite_support_portable.py").is_file():
					root = root.parent / "operator"
				source = (root / "tsuite_support_portable.py").read_text(encoding="utf-8")
				activity = (root / "tsuite_support_activity.py").read_text(encoding="utf-8")
				body = ("CLIENT_SOURCE = " + repr(source) + "\nACTIVITY_SOURCE = " + repr(activity) + "\n" + source).encode()
				start_response("200 OK", [("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", str(len(body))), ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")])
				return [body]
			if path == "/operator-claim" and method == "POST":
				length = int(environ.get("CONTENT_LENGTH", "0"))
				if not 0 < length <= MAX_BODY_BYTES:
					raise ConsoleError("授权请求大小无效")
				body = environ["wsgi.input"].read(length).decode("utf-8")
				result = json.loads(manager("claim", input_text=body))
				return self.json_response(start_response, result)
			if path == "/login" and method == "GET":
				state, verifier = self.store.new_oauth_state()
				query = urllib.parse.urlencode({"client_id": self.settings.client_id, "redirect_uri": self.settings.callback_url, "scope": "read:org", "state": state, "code_challenge": code_challenge(verifier), "code_challenge_method": "S256"})
				oauth_cookie = f"tsuite_support_oauth={state}; Path=/support/auth/github/callback; Secure; HttpOnly; SameSite=Lax; Max-Age={OAUTH_STATE_TTL_SECONDS}"
				return self.redirect(start_response, f"https://github.com/login/oauth/authorize?{query}", [("Set-Cookie", oauth_cookie)])
			if path == "/login/local" and method == "POST":
				form = form_data(environ)
				user = self.store.local_user(form.get("username", ""))
				if not (
					user is not None and bool(user["enabled"])
					and verify_password(form.get("password", ""), str(user["password_hash"]))
				):
					return self.response(
						start_response, HTTPStatus.UNAUTHORIZED,
						page("登录", login_content(True, "账号或密码不正确")),
					)
				challenge_id = self.store.new_local_login_challenge(str(user["username"]))
				cookie = f"tsuite_support_local={challenge_id}; Path=/support/login/local/totp; Secure; HttpOnly; SameSite=Strict; Max-Age={LOCAL_LOGIN_TTL_SECONDS}"
				return self.response(start_response, HTTPStatus.OK, page("身份验证", totp_content()), [("Set-Cookie", cookie)])
			if path == "/login/local/totp" and method == "POST":
				challenge_id = parse_cookie(environ.get("HTTP_COOKIE"), "tsuite_support_local")
				challenge = self.store.local_login_challenge(challenge_id)
				if challenge is None or not challenge_id:
					clear = "tsuite_support_local=; Path=/support/login/local/totp; Secure; HttpOnly; SameSite=Strict; Max-Age=0"
					return self.redirect(start_response, "/support/", [("Set-Cookie", clear)])
				form = form_data(environ)
				user = self.store.local_user(str(challenge["login"]))
				if user is None or not bool(user["enabled"]) or not verify_totp(str(user["totp_secret"]), form.get("totp", "")):
					self.store.fail_local_login_challenge(challenge_id)
					return self.response(
						start_response, HTTPStatus.UNAUTHORIZED,
						page("身份验证", totp_content("动态验证码不正确或已过期")),
					)
				self.store.consume_local_login_challenge(challenge_id)
				session_id, _ = self.store.new_session(str(user["username"]), str(user["display_name"]), bool(user["is_admin"]), "local")
				session_cookie = f"tsuite_support_session={session_id}; Path=/support; Secure; HttpOnly; SameSite=Lax; Max-Age={SESSION_TTL_SECONDS}"
				clear = "tsuite_support_local=; Path=/support/login/local/totp; Secure; HttpOnly; SameSite=Strict; Max-Age=0"
				return self.redirect(start_response, "/support/", [("Set-Cookie", session_cookie), ("Set-Cookie", clear)])
			if path == "/auth/github/callback" and method == "GET":
				query = urllib.parse.parse_qs(environ.get("QUERY_STRING", ""))
				state, code = query.get("state", [""])[-1], query.get("code", [""])[-1]
				browser_state = parse_cookie(environ.get("HTTP_COOKIE"), "tsuite_support_oauth")
				if not browser_state or not secrets.compare_digest(browser_state, state):
					raise ConsoleError("GitHub 登录请求与当前浏览器不匹配")
				verifier = self.store.consume_oauth_state(state)
				if not verifier or not code:
					raise ConsoleError("GitHub 登录状态已失效，请重新登录")
				login, name = github_identity(self.settings, code, verifier)
				session_id, _ = self.store.new_session(login, name, True, "github")
				cookie = f"tsuite_support_session={session_id}; Path=/support; Secure; HttpOnly; SameSite=Lax; Max-Age={SESSION_TTL_SECONDS}"
				clear_oauth = "tsuite_support_oauth=; Path=/support/auth/github/callback; Secure; HttpOnly; SameSite=Lax; Max-Age=0"
				return self.redirect(start_response, "/support/", [("Set-Cookie", cookie), ("Set-Cookie", clear_oauth)])
			if path == "/invite" and method == "GET":
				token = urllib.parse.parse_qs(environ.get("QUERY_STRING", "")).get("token", [""])[-1]
				invite = self.store.local_user_invite(token)
				if invite is None:
					raise ConsoleError("邀请链接无效或已过期")
				if invite["password_hash"] and invite["totp_secret"]:
					return self.response(start_response, HTTPStatus.OK, page("绑定动态验证码", invite_totp_content(token, str(invite["username"]), str(invite["totp_secret"]))))
				return self.response(start_response, HTTPStatus.OK, page("设置本地账号", invite_password_content(token, str(invite["username"]))))
			if path == "/invite/password" and method == "POST":
				form = form_data(environ)
				token = form.get("token", "")
				invite = self.store.local_user_invite(token)
				if invite is None:
					raise ConsoleError("邀请链接无效或已过期")
				password = form.get("password", "")
				if len(password) < 16 or not secrets.compare_digest(password, form.get("confirm_password", "")):
					return self.response(start_response, HTTPStatus.BAD_REQUEST, page("设置本地账号", invite_password_content(token, str(invite["username"]), "密码至少 16 位，且两次输入必须一致")))
				secret = new_totp_secret()
				self.store.prepare_local_user_invite(token, hash_password(password), secret)
				return self.response(start_response, HTTPStatus.OK, page("绑定动态验证码", invite_totp_content(token, str(invite["username"]), secret)))
			if path == "/invite/totp" and method == "POST":
				form = form_data(environ)
				token = form.get("token", "")
				invite = self.store.local_user_invite(token)
				if invite is None or not invite["password_hash"] or not invite["totp_secret"]:
					raise ConsoleError("邀请状态无效或已过期")
				if not verify_totp(str(invite["totp_secret"]), form.get("totp", "")):
					self.store.fail_local_user_invite(token)
					return self.response(start_response, HTTPStatus.BAD_REQUEST, page("绑定动态验证码", invite_totp_content(token, str(invite["username"]), str(invite["totp_secret"]), "动态验证码不正确，请检查手机时间后重试")))
				self.store.activate_local_user_invite(token)
				content = '<section class="card" style="max-width:520px;margin:80px auto;text-align:center"><h1>账号已启用</h1><p>密码和动态验证码绑定成功，现在可以登录支持工作台。</p><a class="button" href="/support/">前往登录</a></section>'
				return self.response(start_response, HTTPStatus.OK, page("账号已启用", content))
			session_id, session = self.require_session(environ)
			if path == "/logout" and method == "POST":
				form = form_data(environ)
				if session is None or not secrets.compare_digest(form.get("csrf", ""), str(session["csrf"])):
					raise ConsoleError("请求校验失败，请刷新页面后重试")
				self.store.delete_session(session_id)
				return self.redirect(start_response, "/support/", [("Set-Cookie", "tsuite_support_session=; Path=/support; Secure; HttpOnly; SameSite=Lax; Max-Age=0")])
			if session is None:
				return self.response(start_response, HTTPStatus.UNAUTHORIZED, page("登录", login_content(bool(self.settings.local_admin_user))))
			if path == "/users" and method == "GET":
				if not bool(session["is_admin"]):
					return self.response(start_response, HTTPStatus.FORBIDDEN, page("无权访问", "<h1>无权访问</h1>"))
				return self.users_page(start_response, session)
			if path == "/users/invite" and method == "POST":
				if not bool(session["is_admin"]):
					return self.response(start_response, HTTPStatus.FORBIDDEN, page("无权访问", "<h1>无权访问</h1>"))
				form = form_data(environ)
				if not secrets.compare_digest(form.get("csrf", ""), str(session["csrf"])):
					raise ConsoleError("请求校验失败，请刷新页面后重试")
				username = form.get("username", "")
				display_name = form.get("display_name", "").strip()
				role = form.get("role", "operator")
				if not 3 <= len(username) <= 64 or any(character not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-" for character in username):
					raise ConsoleError("用户名无效")
				if not display_name or len(display_name) > 80 or any(ord(character) < 32 for character in display_name):
					raise ConsoleError("显示名称无效")
				if role not in {"operator", "admin"} or self.store.local_user(username) is not None:
					raise ConsoleError("角色无效或用户名已存在")
				token = self.store.new_local_user_invite(username, display_name, role == "admin", str(session["login"]))
				invite_url = f"{self.settings.public_url}/invite?" + urllib.parse.urlencode({"token": token})
				content = f'<header><h1>邀请已创建</h1><a class="button" href="/support/users">返回用户管理</a></header><section class="card"><p>此链接 30 分钟内有效且只能使用一次，请通过安全渠道发给 <strong>{html.escape(username)}</strong>。</p><div class="secret-heading"><h2>邀请链接</h2><button type="button" class="copy-button" data-copy-target="invite-link">复制</button></div><div id="invite-link" class="secret">{html.escape(invite_url)}</div></section>'
				return self.response(start_response, HTTPStatus.OK, page("邀请已创建", content))
			if path.startswith("/users/") and path.endswith("/reset-totp") and method == "POST":
				if not bool(session["is_admin"]):
					return self.response(start_response, HTTPStatus.FORBIDDEN, page("无权访问", "<h1>无权访问</h1>"))
				form = form_data(environ)
				if not secrets.compare_digest(form.get("csrf", ""), str(session["csrf"])):
					raise ConsoleError("请求校验失败，请刷新页面后重试")
				username = path.removeprefix("/users/").removesuffix("/reset-totp")
				token = self.store.new_local_user_totp_reset(username, str(session["login"]))
				invite_url = f"{self.settings.public_url}/invite?" + urllib.parse.urlencode({"token": token})
				content = f'<header><h1>TOTP 重绑链接已创建</h1><a class="button" href="/support/users">返回用户管理</a></header><section class="card"><p>链接 30 分钟内有效且只能使用一次。完成绑定后，该用户现有登录会话会被撤销。</p><div class="secret-heading"><h2>重绑链接</h2><button type="button" class="copy-button" data-copy-target="invite-link">复制</button></div><div id="invite-link" class="secret">{html.escape(invite_url)}</div></section>'
				return self.response(start_response, HTTPStatus.OK, page("重绑 TOTP", content))
			if path.startswith("/users/") and path.endswith("/toggle") and method == "POST":
				if not bool(session["is_admin"]):
					return self.response(start_response, HTTPStatus.FORBIDDEN, page("无权访问", "<h1>无权访问</h1>"))
				form = form_data(environ)
				if not secrets.compare_digest(form.get("csrf", ""), str(session["csrf"])):
					raise ConsoleError("请求校验失败，请刷新页面后重试")
				username = path.removeprefix("/users/").removesuffix("/toggle")
				user = self.store.local_user(username)
				if user is None or username == str(session["login"]):
					raise ConsoleError("不能修改当前用户或用户不存在")
				self.store.set_local_user_enabled(username, not bool(user["enabled"]))
				return self.redirect(start_response, "/support/users")
			if path == "/" and method == "GET":
				return self.dashboard(start_response, session)
			if path == "/sessions" and method == "GET":
				summary, groups = self.session_fragments(session)
				return self.json_response(start_response, {"summary": summary, "groups": groups})
			if path == "/session" and method == "POST":
				form = form_data(environ)
				if not secrets.compare_digest(form.get("csrf", ""), str(session["csrf"])):
					raise ConsoleError("请求校验失败，请刷新页面后重试")
				customer = form.get("customer", "")
				purpose = form.get("purpose", "").strip()
				if len(purpose) > 200 or any(ord(character) < 32 for character in purpose):
					raise ConsoleError("支持用途最多为 200 个可见字符")
				platform = form.get("platform", "linux")
				if platform not in ("linux", "windows"):
					raise ConsoleError("请选择 Linux 或受支持的 Windows")
				platform_args = ("--platform", platform) if platform == "windows" else ()
				created = json.loads(manager(
					"create", customer,
					"--created-by", str(session["login"]),
					"--purpose", purpose,
					*platform_args,
				))
				if not isinstance(created, dict) or not isinstance(created.get("token"), str):
					raise ConsoleError("支持会话服务返回无效数据")
				operator_section = ""
				if isinstance(created.get("operator_claim_token"), str):
					grant = json.dumps({"id": created["id"], "token": created["operator_claim_token"], "url": self.settings.public_url}, separators=(",", ":"))
					command = "printf '%s\n' " + shlex.quote(grant) + ' | python3 -c "$(curl -fsSL --proto =https --tlsv1.2 ' + shlex.quote(self.settings.public_url + "/operator-client") + ')"'
					operator_section = '<div class="secret-section"><div class="secret-heading"><h2>支持机执行命令（Linux 终端）</h2><button type="button" class="copy-button" data-copy-target="operator-command">复制</button></div><div id="operator-command" class="secret">' + html.escape(command) + '</div><p class="muted">自动生成本机密钥并领取一次性授权，无需登录 GitHub 或部署控制机。客户尚未接入时自动等待。请勿分享此命令。</p></div>'
				legacy_code = ""
				if created.get("auth_mode") != "enrollment-key":
					legacy_code = f'<div class="secret-section"><h2>一次性支持会话码</h2><button type="button" class="copy-button" data-copy-target="support-token">复制</button><div id="support-token" class="secret token">{html.escape(created["token"])}</div></div>'
				instructions = ("请通过安全渠道发送客户命令；命令中的链接就是接入凭据，默认 15 分钟有效，无需另输会话码。"
					if created.get("auth_mode") == "enrollment-key" else "请将命令和会话码通过两个独立安全渠道发送给客户。")
				content = f"""<header><h1>支持会话已创建</h1><a href="/support/">返回会话列表</a></header><section class="card"><p>会话 ID：<code>{html.escape(str(created['id']))}</code>。以下内容仅显示一次，且不会被管理页面持久保存。</p>
<div class="secret-section"><div class="secret-heading"><h2>客户执行命令（{"管理员 PowerShell" if platform == "windows" else "Linux 终端"}）</h2><button type="button" class="copy-button" data-copy-target="customer-command">复制</button></div><div id="customer-command" class="secret">{html.escape(str(created['customer_command']))}</div></div>
{operator_section}{legacy_code}<p class="muted">{instructions}</p></section>"""
				return self.response(start_response, HTTPStatus.OK, page("会话已创建", content))
			if path.startswith("/session/") and path.endswith("/close") and method == "POST":
				target = path.removeprefix("/session/").removesuffix("/close")
				if not target or "/" in target:
					raise ConsoleError("会话 ID 无效")
				form = form_data(environ)
				if not secrets.compare_digest(form.get("csrf", ""), str(session["csrf"])):
					raise ConsoleError("请求校验失败，请刷新页面后重试")
				manager("close", target, "--closed-by", str(session["login"]))
				return self.redirect(start_response, "/support/")
			if path.startswith("/session/"):
				target = path.removeprefix("/session/")
				if not target or "/" in target:
					raise ConsoleError("会话 ID 无效")
				if method == "GET":
					info = json.loads(manager("show", target))
					if not isinstance(info, dict):
						raise ConsoleError("支持会话服务返回无效数据")
					keys = [key for key in DETAIL_FIELD_ORDER if key in info]
					keys.extend(key for key in info if key not in DETAIL_FIELD_LABELS)
					fields = []
					for key in keys:
						label = DETAIL_FIELD_LABELS.get(key, key)
						value = status_badge(str(info[key])) if key == "status" else html.escape(detail_value(key, info[key]))
						fields.append(f"<tr><th>{html.escape(label)}</th><td>{value}</td></tr>")
					escaped_target = html.escape(target)
					status = str(info.get("status", ""))
					destructive_action = ""
					action_note = "当前状态不支持关闭操作。"
					if status in CLOSABLE_STATUSES:
						action_note = "关闭会话会先调度客户侧清理，再撤销连接，且无法恢复。"
						destructive_action = (
							f'<form method="post" action="/support/session/{escaped_target}/close" '
							'onsubmit="return confirm(\'确定关闭这个支持会话吗？系统会先调度客户侧清理，再撤销连接。\')">'
							f'<input type="hidden" name="csrf" value="{html.escape(str(session["csrf"]))}">'
							'<button type="submit" class="danger">关闭会话</button></form>'
						)
					elif status == "revoking":
						action_note = "会话正在关闭，请稍后刷新状态。"
					elif status in {"closed", "expired"}:
						action_note = "该会话已经结束，不会再接受客户连接。"
					detail_actions = (
						f'<div class="danger-zone"><p>{action_note}</p><div class="detail-actions">'
						f'<a class="button" href="/support/">关闭</a>{destructive_action}</div></div>'
					)
					content = (
						f'<header><h1>会话 {escaped_target}</h1></header>'
						f'<section class="card"><table class="detail-table">{"".join(fields)}</table>{detail_actions}</section>'
					)
					return self.response(start_response, HTTPStatus.OK, page("会话详情", content))
			return self.response(start_response, HTTPStatus.NOT_FOUND, page("未找到", "<h1>未找到页面</h1>"))
		except (ConsoleError, ValueError, TypeError):
			return self.response(start_response, HTTPStatus.BAD_REQUEST, page("操作失败", "<h1>操作失败</h1><p class=\"error\">请求未完成。请刷新后重试；如仍失败，请查看堡垒机服务日志。</p>"))


class QuietHandler(WSGIRequestHandler):
	def log_message(self, format: str, *args: Any) -> None:
		return


def main() -> int:
	config_path = pathlib.Path(os.environ.get("TSUITE_SUPPORT_CONSOLE_CONFIG", "/etc/tsuite-support-console/config.json"))
	settings = Settings.load(config_path)
	application = Application(settings)
	with contextlib.suppress(ConsoleError):
		manager("list")
	with make_server(settings.listen_host, settings.listen_port, application, handler_class=QuietHandler) as server:
		server.serve_forever()
	return 0


if __name__ == "__main__":
	raise SystemExit(main())

#!/usr/bin/env python3
"""GitHub-authenticated management console for temporary TSuite support sessions."""

from __future__ import annotations

import base64
import contextlib
import hashlib
import html
import json
import os
import pathlib
import secrets
import sqlite3
import subprocess
import sys
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
ACTION = "/usr/local/bin/tsuite-support-console-action"
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
	"status": "状态",
	"created_at": "创建时间",
	"token_expires_at": "会话码到期时间",
	"expires_at": "会话到期时间",
	"enrolled_at": "客户接入时间",
	"revoking_at": "开始关闭时间",
	"closed_at": "关闭时间",
	"expired_at": "过期时间",
	"remote_port": "回环端口",
	"tunnel_user": "隧道用户",
	"tunnel_reachable": "隧道可达",
	"customer_host_key": "客户 SSH Host Key",
}
DETAIL_FIELD_ORDER = tuple(DETAIL_FIELD_LABELS)
TIMESTAMP_FIELDS = {key for key in DETAIL_FIELD_LABELS if key.endswith("_at")}
CHINA_TIMEZONE = timezone(timedelta(hours=8))


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
				"""
			)

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

	def new_session(self, login: str, name: str) -> tuple[str, str]:
		session_id, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
		with self.connection() as connection:
			connection.execute(
				"INSERT INTO web_session(id, login, name, csrf, expires_at) VALUES (?, ?, ?, ?, ?)",
				(session_id, login, name, csrf, int(time.time()) + SESSION_TTL_SECONDS),
			)
		return session_id, csrf

	def session(self, session_id: str | None) -> sqlite3.Row | None:
		if not session_id:
			return None
		with self.connection() as connection:
			return connection.execute(
				"SELECT login, name, csrf, expires_at FROM web_session WHERE id = ? AND expires_at > ?",
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


def manager(*arguments: str) -> str:
	try:
		result = subprocess.run(
			[ACTION, *arguments],
			check=False, capture_output=True, text=True, timeout=30,
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
	return str(value)


def status_badge(status: str) -> str:
	label, style = STATUS_PRESENTATION.get(status, (status, "neutral"))
	return f'<span class="badge badge-{style}">{html.escape(label)}</span>'


def page(title: str, content: str) -> bytes:
	return f"""<!doctype html>
<html lang=\"zh-CN\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
<title>{html.escape(title)} · TSuite Support</title>
<style>
*{{box-sizing:border-box}} body{{max-width:1080px;margin:0 auto;padding:36px 24px 64px;color:#17212b;font:15px system-ui,-apple-system,\"Segoe UI\",sans-serif;background:#f5f7fa}}
header{{display:flex;justify-content:space-between;align-items:center;padding:0 0 24px}} h1{{margin:0;font-size:26px;letter-spacing:-.02em}} h2,h3{{margin-top:0}} h2{{font-size:19px}} h3{{font-size:17px}}
a{{color:#075985;text-decoration:none}} a:hover{{text-decoration:underline}} button,a.button{{display:inline-flex;align-items:center;justify-content:center;border:1px solid #cbd5e1;border-radius:7px;padding:9px 14px;color:#075985;background:#fff;cursor:pointer}} a.button:hover{{text-decoration:none}} button.primary{{border-color:#0369a1;color:#fff;background:#0369a1}} button.danger{{border-color:#dc2626;color:#fff;background:#dc2626}} button.compact{{padding:6px 10px;font-size:13px}} button:hover,a.button:hover{{filter:brightness(.97)}}
input{{min-width:280px;border:1px solid #cbd5e1;border-radius:7px;padding:10px 12px;background:#fff}} input:focus{{outline:3px solid #bae6fd;border-color:#0284c7}}
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
						'onsubmit="return confirm(\'确定关闭这个支持会话吗？关闭后客户连接将立即中断。\')">'
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
		groups = "".join(group_cards) or '<div class="card empty">还没有支持会话</div>'
		summary = (
			f'<span><strong>{len(grouped)}</strong> 个客户环境</span>'
			f'<span><strong>{sum(map(len, grouped.values()))}</strong> 次历史会话</span>'
			f'<span><strong>{active_total}</strong> 个活动会话</span>'
		)
		return summary, groups

	def dashboard(self, start_response: Callable[..., Any], session: sqlite3.Row) -> list[bytes]:
		content = f"""<header><h1>TSuite 支持管理</h1><form method=\"post\" action=\"/support/logout\"><input type=\"hidden\" name=\"csrf\" value=\"{html.escape(str(session['csrf']))}\"><button>退出 {html.escape(str(session['login']))}</button></form></header>
<section class=\"card\"><h2>新建支持会话</h2><p class=\"muted\">为同一台客户机器使用固定的环境标识，例如 <code>dtaut-srm-prod-01</code>。每次连接都会自动生成新的完整会话 ID。</p>
<form class=\"create-form\" method=\"post\" action=\"/support/session\"><input type=\"hidden\" name=\"csrf\" value=\"{html.escape(str(session['csrf']))}\"><label>客户环境标识<input name=\"customer\" required autocomplete=\"off\" placeholder=\"例如 dtaut-srm-prod-01\" pattern=\"[a-z0-9][a-z0-9-]{{0,47}}\"></label><button class=\"primary\">创建会话</button></form>
<div id=\"session-summary\" class=\"summary\" aria-live=\"polite\"><span class=\"loading-label\">正在读取会话数据…</span></div></section>
<section><h2>客户环境与会话</h2><div id=\"session-groups\" class=\"group-list\" aria-live=\"polite\" aria-busy=\"true\"><div class=\"card loading\"><span class=\"spinner\"></span><span>正在加载会话列表…</span></div></div></section>"""
		return self.response(start_response, HTTPStatus.OK, page("支持管理", content))

	def __call__(self, environ: dict[str, Any], start_response: Callable[..., Any]) -> list[bytes]:
		self.store.cleanup()
		path = environ.get("PATH_INFO", "/")
		method = environ.get("REQUEST_METHOD", "GET")
		try:
			if path == "/login" and method == "GET":
				state, verifier = self.store.new_oauth_state()
				query = urllib.parse.urlencode({"client_id": self.settings.client_id, "redirect_uri": self.settings.callback_url, "scope": "read:org", "state": state, "code_challenge": code_challenge(verifier), "code_challenge_method": "S256"})
				return self.redirect(start_response, f"https://github.com/login/oauth/authorize?{query}")
			if path == "/auth/github/callback" and method == "GET":
				query = urllib.parse.parse_qs(environ.get("QUERY_STRING", ""))
				state, code = query.get("state", [""])[-1], query.get("code", [""])[-1]
				verifier = self.store.consume_oauth_state(state)
				if not verifier or not code:
					raise ConsoleError("GitHub 登录状态已失效，请重新登录")
				login, name = github_identity(self.settings, code, verifier)
				session_id, _ = self.store.new_session(login, name)
				cookie = f"tsuite_support_session={session_id}; Path=/support; Secure; HttpOnly; SameSite=Lax; Max-Age={SESSION_TTL_SECONDS}"
				return self.redirect(start_response, "/support/", [("Set-Cookie", cookie)])
			session_id, session = self.require_session(environ)
			if path == "/logout" and method == "POST":
				form = form_data(environ)
				if session is None or not secrets.compare_digest(form.get("csrf", ""), str(session["csrf"])):
					raise ConsoleError("请求校验失败，请刷新页面后重试")
				self.store.delete_session(session_id)
				return self.redirect(start_response, "/support/", [("Set-Cookie", "tsuite_support_session=; Path=/support; Secure; HttpOnly; SameSite=Lax; Max-Age=0")])
			if session is None:
				return self.response(start_response, HTTPStatus.UNAUTHORIZED, page("需要登录", "<h1>TSuite 支持管理</h1><p><a href=\"/support/login\">使用 GitHub 登录</a></p>"))
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
				created = json.loads(manager("create", customer))
				if not isinstance(created, dict) or not isinstance(created.get("token"), str):
					raise ConsoleError("支持会话服务返回无效数据")
				content = f"""<header><h1>支持会话已创建</h1><a href=\"/support/\">返回会话列表</a></header><section class=\"card\"><p>会话 ID：<code>{html.escape(str(created['id']))}</code>。以下内容仅显示一次，且不会被管理页面持久保存。</p>
<div class=\"secret-section\"><div class=\"secret-heading\"><h2>客户执行命令</h2><button type=\"button\" class=\"copy-button\" data-copy-target=\"customer-command\">复制</button></div><div id=\"customer-command\" class=\"secret\">{html.escape(str(created['customer_command']))}</div></div>
<div class=\"secret-section\"><div class=\"secret-heading\"><h2>一次性支持会话码</h2><button type=\"button\" class=\"copy-button\" data-copy-target=\"support-token\">复制</button></div><div id=\"support-token\" class=\"secret token\">{html.escape(created['token'])}</div></div>
<p class=\"muted\">请将命令和会话码通过两个独立安全渠道发送给客户；会话码默认 15 分钟后失效。</p></section>"""
				return self.response(start_response, HTTPStatus.OK, page("会话已创建", content))
			if path.startswith("/session/") and path.endswith("/close") and method == "POST":
				target = path.removeprefix("/session/").removesuffix("/close")
				if not target or "/" in target:
					raise ConsoleError("会话 ID 无效")
				form = form_data(environ)
				if not secrets.compare_digest(form.get("csrf", ""), str(session["csrf"])):
					raise ConsoleError("请求校验失败，请刷新页面后重试")
				manager("close", target)
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
						action_note = "关闭会话会立即撤销客户连接，且无法恢复。"
						destructive_action = (
							f'<form method="post" action="/support/session/{escaped_target}/close" '
							'onsubmit="return confirm(\'确定关闭这个支持会话吗？关闭后客户连接将立即中断。\')">'
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
		except (ConsoleError, json.JSONDecodeError):
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

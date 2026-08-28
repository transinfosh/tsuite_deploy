#!/usr/bin/env python3
"""Call the bastion's forced support-session action over a pinned SSH connection."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass


CUSTOMER_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,47}$")
SESSION_RE = re.compile(r"^[a-f0-9]{12}$")
CONTROL_PATH = "/var/lib/tsuite-support-console/ssh-control-%C"


class RemoteActionError(RuntimeError):
	pass


@dataclass(frozen=True)
class Settings:
	host: str
	port: int
	user: str
	identity_file: pathlib.Path
	known_hosts_file: pathlib.Path

	@classmethod
	def load(cls, path: pathlib.Path) -> "Settings":
		with path.open(encoding="utf-8") as handle:
			value = json.load(handle)
		settings = cls(
			host=str(value["host"]),
			port=int(value.get("port", 22)),
			user=str(value["user"]),
			identity_file=pathlib.Path(value["identity_file"]),
			known_hosts_file=pathlib.Path(value["known_hosts_file"]),
		)
		settings.validate()
		return settings

	def validate(self) -> None:
		if not re.fullmatch(r"[A-Za-z0-9.-]+", self.host):
			raise RemoteActionError("堡垒机域名无效")
		if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", self.user):
			raise RemoteActionError("堡垒机用户名无效")
		if not 1 <= self.port <= 65535:
			raise RemoteActionError("堡垒机 SSH 端口无效")
		for path in (self.identity_file, self.known_hosts_file):
			if not path.is_file():
				raise RemoteActionError(f"SSH 文件不存在: {path}")


def customer(value: str) -> str:
	if not CUSTOMER_RE.fullmatch(value):
		raise argparse.ArgumentTypeError("客户标识无效")
	return value


def session_id(value: str) -> str:
	if not SESSION_RE.fullmatch(value):
		raise argparse.ArgumentTypeError("会话 ID 无效")
	return value


def parser() -> argparse.ArgumentParser:
	root = argparse.ArgumentParser(description=__doc__)
	subparsers = root.add_subparsers(dest="action", required=True)
	create = subparsers.add_parser("create")
	create.add_argument("customer", type=customer)
	show = subparsers.add_parser("show")
	show.add_argument("session_id", type=session_id)
	close = subparsers.add_parser("close")
	close.add_argument("session_id", type=session_id)
	subparsers.add_parser("list")
	return root


def main() -> int:
	args = parser().parse_args()
	settings = Settings.load(pathlib.Path("/etc/tsuite-support-console/action.json"))
	remote_arguments = [args.action]
	if args.action == "create":
		remote_arguments.append(args.customer)
	elif args.action in {"show", "close"}:
		remote_arguments.append(args.session_id)
	result = subprocess.run(
		[
			"ssh", "-F", "none", "-T", "-i", str(settings.identity_file),
			"-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
			"-o", "StrictHostKeyChecking=yes",
			"-o", f"UserKnownHostsFile={settings.known_hosts_file}",
			"-o", "ClearAllForwardings=yes", "-p", str(settings.port),
			"-o", "ControlMaster=auto",
			"-o", "ControlPersist=3600",
			"-o", f"ControlPath={CONTROL_PATH}",
			f"{settings.user}@{settings.host}", *remote_arguments,
		],
		check=False,
		stdin=subprocess.DEVNULL,
		stdout=sys.stdout,
		stderr=sys.stderr,
	)
	return result.returncode


if __name__ == "__main__":
	try:
		raise SystemExit(main())
	except (RemoteActionError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
		print(f"错误: {error}", file=sys.stderr)
		raise SystemExit(1)

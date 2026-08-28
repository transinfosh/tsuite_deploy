#!/usr/bin/env python3
"""Narrow root-only bridge between the support console and session manager."""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import shlex
import subprocess
import sys


CONFIG = "/etc/tsuite-support/config.json"
MANAGER = "/usr/local/sbin/tsuite-support-session"
OPERATOR_PUBLIC_KEY = "/etc/tsuite-support-console/operator_ed25519.pub"
CUSTOMER_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,47}$")
SESSION_RE = re.compile(r"^[a-f0-9]{12}$")


class ActionError(RuntimeError):
	pass


def run_manager(*arguments: str) -> int:
	command = [MANAGER, "--config", CONFIG, *arguments]
	if os.geteuid() != 0:
		command = ["sudo", "-n", *command]
	result = subprocess.run(
		command,
		check=False,
		stdout=sys.stdout,
		stderr=sys.stderr,
	)
	return result.returncode


def customer(value: str) -> str:
	if not CUSTOMER_RE.fullmatch(value):
		raise argparse.ArgumentTypeError("客户标识仅允许小写字母、数字和连字符")
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


def main(arguments: list[str] | None = None) -> int:
	arguments = list(sys.argv[1:] if arguments is None else arguments)
	if arguments == ["--forced"]:
		try:
			arguments = shlex.split(os.environ.get("SSH_ORIGINAL_COMMAND", ""))
		except ValueError as error:
			raise ActionError("远程操作格式无效") from error
	args = parser().parse_args(arguments)
	if args.action == "create":
		key = pathlib.Path(OPERATOR_PUBLIC_KEY)
		if not key.is_file():
			raise ActionError("控制台操作员公钥不存在")
		return run_manager(
			"create", "--customer", args.customer, "--operator-public-key", str(key), "--json"
		)
	if args.action == "show":
		return run_manager("show", args.session_id, "--json")
	if args.action == "close":
		return run_manager("close", args.session_id)
	return run_manager("list")


if __name__ == "__main__":
	try:
		raise SystemExit(main())
	except ActionError as error:
		print(f"错误: {error}", file=sys.stderr)
		raise SystemExit(1)

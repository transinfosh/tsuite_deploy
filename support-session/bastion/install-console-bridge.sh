#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_PUBLIC_KEY=""
OPERATOR_PUBLIC_KEY=""
OPERATOR_USER="tsuite-operator"

die() {
	printf '错误: %s\n' "$*" >&2
	exit 1
}

while (($#)); do
	case "$1" in
		--bridge-public-key) BRIDGE_PUBLIC_KEY="${2:-}"; shift ;;
		--operator-public-key) OPERATOR_PUBLIC_KEY="${2:-}"; shift ;;
		--operator-user) OPERATOR_USER="${2:-}"; shift ;;
		*) die "未知参数: $1" ;;
	esac
	shift
done

[[ "$EUID" -eq 0 ]] || die "请使用 sudo 运行"
[[ -f "$BRIDGE_PUBLIC_KEY" ]] || die "缺少控制台桥接公钥"
[[ -f "$OPERATOR_PUBLIC_KEY" ]] || die "缺少客户运维公钥"
[[ "$OPERATOR_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "运维用户名无效"
id "$OPERATOR_USER" >/dev/null 2>&1 || die "运维用户不存在: $OPERATOR_USER"
[[ -x /usr/local/sbin/tsuite-support-session ]] || die "support-session 尚未安装"
command -v visudo >/dev/null 2>&1 || die "缺少 visudo"

operator_group="$(id -gn "$OPERATOR_USER")"
install -d -m 0750 -o root -g "$operator_group" /etc/tsuite-support-console
install -m 0755 -o root -g root "$SCRIPT_DIR/tsuite_support_console_action.py" \
	/usr/local/sbin/tsuite-support-console-action
install -m 0644 -o root -g root "$OPERATOR_PUBLIC_KEY" \
	/etc/tsuite-support-console/operator_ed25519.pub

sudoers_file="/etc/sudoers.d/tsuite-support-session"
[[ -f "$sudoers_file" ]] || die "缺少 support-session 基础 sudoers 配置"
visudo -cf "$sudoers_file" >/dev/null || die "support-session 基础 sudoers 配置无效"

operator_home="$(getent passwd "$OPERATOR_USER" | cut -d: -f6)"
[[ -n "$operator_home" && "$operator_home" == /* ]] || die "无法读取运维用户 Home"
install -d -m 0700 -o "$OPERATOR_USER" -g "$operator_group" "$operator_home/.ssh"
authorized_keys="$operator_home/.ssh/authorized_keys"
[[ -f "$authorized_keys" ]] || install -m 0600 -o "$OPERATOR_USER" -g "$operator_group" /dev/null "$authorized_keys"

python3 - "$BRIDGE_PUBLIC_KEY" "$authorized_keys" "$OPERATOR_USER" <<'PY'
import os
import pathlib
import pwd
import sys
import tempfile

public_key_path = pathlib.Path(sys.argv[1])
authorized_keys_path = pathlib.Path(sys.argv[2])
username = sys.argv[3]
parts = public_key_path.read_text(encoding="utf-8").strip().split()
if len(parts) < 2 or parts[0] != "ssh-ed25519":
    raise SystemExit("控制台桥接公钥必须是 Ed25519")
public_key = " ".join(parts[:2])
marker = "tsuite-support-console-bridge"
line = (
    'command="/usr/local/sbin/tsuite-support-console-action --forced",'
    'restrict '
    f'{public_key} {marker}\n'
)
existing = authorized_keys_path.read_text(encoding="utf-8").splitlines(keepends=True)
existing = [item for item in existing if marker not in item]
fd, temporary_name = tempfile.mkstemp(prefix=".authorized_keys.", dir=authorized_keys_path.parent)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    handle.writelines(existing)
    handle.write(line)
    handle.flush()
    os.fsync(handle.fileno())
account = pwd.getpwnam(username)
os.chown(temporary_name, account.pw_uid, account.pw_gid)
os.chmod(temporary_name, 0o600)
os.replace(temporary_name, authorized_keys_path)
PY

printf '堡垒机控制台桥接安装完成。\n'

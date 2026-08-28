#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_PUBLIC_KEY=""
EDGE_OPERATOR_PUBLIC_KEY=""
OPERATOR_USER="tsuite-operator"

die() {
	printf '错误: %s\n' "$*" >&2
	exit 1
}

while (($#)); do
	case "$1" in
		--bridge-public-key) BRIDGE_PUBLIC_KEY="${2:-}"; shift ;;
		--edge-operator-public-key) EDGE_OPERATOR_PUBLIC_KEY="${2:-}"; shift ;;
		--operator-user) OPERATOR_USER="${2:-}"; shift ;;
		*) die "未知参数: $1" ;;
	esac
	shift
done

[[ "$EUID" -eq 0 ]] || die "请使用 sudo 运行"
[[ -f "$BRIDGE_PUBLIC_KEY" ]] || die "缺少控制台桥接公钥"
[[ -f "$EDGE_OPERATOR_PUBLIC_KEY" ]] || die "缺少控制机 edge forced proxy 公钥"
[[ "$OPERATOR_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "运维用户名无效"
id "$OPERATOR_USER" >/dev/null 2>&1 || die "运维用户不存在: $OPERATOR_USER"
[[ -x /usr/local/sbin/tsuite-support-session ]] || die "support-session 尚未安装"
command -v visudo >/dev/null 2>&1 || die "缺少 visudo"

operator_group="$(id -gn "$OPERATOR_USER")"
install -d -m 0750 -o root -g "$operator_group" /etc/tsuite-support-console
install -m 0755 -o root -g root "$SCRIPT_DIR/tsuite_support_console_action.py" \
	/usr/local/sbin/tsuite-support-console-action
install -m 0755 -o root -g root "$SCRIPT_DIR/tsuite-support-operator-shell" \
	/usr/local/sbin/tsuite-support-operator-shell
# sshd launches authorized_keys forced commands through the account shell.
# A nologin shell blocks the forced command, while this wrapper permits only the
# two installed TSuite entry points and rejects interactive/arbitrary commands.
usermod --shell /usr/local/sbin/tsuite-support-operator-shell "$OPERATOR_USER"

sudoers_file="/etc/sudoers.d/tsuite-support-session"
[[ -f "$sudoers_file" ]] || die "缺少 support-session 基础 sudoers 配置"
visudo -cf "$sudoers_file" >/dev/null || die "support-session 基础 sudoers 配置无效"

operator_home="$(getent passwd "$OPERATOR_USER" | cut -d: -f6)"
[[ -n "$operator_home" && "$operator_home" == /* ]] || die "无法读取运维用户 Home"
install -d -m 0700 -o "$OPERATOR_USER" -g "$operator_group" "$operator_home/.ssh"
authorized_keys="$operator_home/.ssh/authorized_keys"
[[ -f "$authorized_keys" ]] || install -m 0600 -o "$OPERATOR_USER" -g "$operator_group" /dev/null "$authorized_keys"

python3 - "$BRIDGE_PUBLIC_KEY" "$EDGE_OPERATOR_PUBLIC_KEY" "$authorized_keys" "$OPERATOR_USER" <<'PY'
import os
import pathlib
import pwd
import sys
import tempfile

bridge_path = pathlib.Path(sys.argv[1])
edge_operator_path = pathlib.Path(sys.argv[2])
authorized_keys_path = pathlib.Path(sys.argv[3])
username = sys.argv[4]

def public_key(path, label):
    parts = path.read_text(encoding="utf-8").strip().split()
    if len(parts) < 2 or parts[0] != "ssh-ed25519":
        raise SystemExit(f"{label}必须是 Ed25519")
    return " ".join(parts[:2])

bridge_key = public_key(bridge_path, "控制台桥接公钥")
edge_operator_key = public_key(edge_operator_path, "edge forced proxy 公钥")
bridge_marker = "tsuite-support-console-bridge"
edge_marker = "tsuite-support-edge-proxy"
bridge_line = (
    'command="/usr/local/sbin/tsuite-support-console-action --forced",'
    'restrict '
    f'{bridge_key} {bridge_marker}\n'
)
edge_line = (
    'command="/usr/local/sbin/tsuite-support-console-action --proxy",restrict '
    f'{edge_operator_key} {edge_marker}\n'
)
existing = authorized_keys_path.read_text(encoding="utf-8").splitlines(keepends=True)
existing = [
    item for item in existing
    if bridge_marker not in item
    and edge_marker not in item
    and "tsuite-support-edge-operator" not in item
    and "tsuite-control-to-edge" not in item
]
fd, temporary_name = tempfile.mkstemp(prefix=".authorized_keys.", dir=authorized_keys_path.parent)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    handle.writelines(existing)
    handle.write(bridge_line)
    handle.write(edge_line)
    handle.flush()
    os.fsync(handle.fileno())
account = pwd.getpwnam(username)
os.chown(temporary_name, account.pw_uid, account.pw_gid)
os.chmod(temporary_name, 0o600)
os.replace(temporary_name, authorized_keys_path)
PY

printf '堡垒机控制台桥接安装完成。\n'

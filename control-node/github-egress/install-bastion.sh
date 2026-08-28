#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_KEY=""
EGRESS_USER="tsuite-github-egress"
EGRESS_HOME="/var/empty/tsuite-github-egress"
TINYPROXY_CONFIG="/etc/tinyproxy/tinyproxy.conf"
SSHD_CONFIG="/etc/ssh/sshd_config.d/85-tsuite-github-egress.conf"
BACKUP_DIR=""
INSTALL_COMMITTED=0

die() {
	printf '错误: %s\n' "$*" >&2
	exit 1
}

restore_previous_config() {
	local target backup
	[[ "$INSTALL_COMMITTED" -eq 0 && -n "$BACKUP_DIR" ]] || return 0
	for target in "$TINYPROXY_CONFIG" "$SSHD_CONFIG"; do
		backup="$BACKUP_DIR${target}"
		if [[ -f "$backup" ]]; then
			install -D -m "$(stat -c '%a' "$backup")" "$backup" "$target"
		else
			unlink "$target" 2>/dev/null || true
		fi
	done
	sshd -t >/dev/null 2>&1 && systemctl reload ssh.service >/dev/null 2>&1 || true
	systemctl restart tinyproxy.service >/dev/null 2>&1 || true
}

trap restore_previous_config EXIT

while (($#)); do
	case "$1" in
		--public-key) PUBLIC_KEY="${2:-}"; shift ;;
		*) die "未知参数: $1" ;;
	esac
	shift
done

[[ "$EUID" -eq 0 ]] || die "请使用 sudo 运行"
[[ -f "$PUBLIC_KEY" ]] || die "缺少控制机出站公钥"
command -v tinyproxy >/dev/null 2>&1 || die "缺少 tinyproxy"

BACKUP_DIR="$(mktemp -d /var/backups/tsuite-github-egress.XXXXXX)"
for config in "$TINYPROXY_CONFIG" "$SSHD_CONFIG"; do
	if [[ -f "$config" ]]; then
		install -D -m "$(stat -c '%a' "$config")" "$config" "$BACKUP_DIR$config"
	fi
done

getent group "$EGRESS_USER" >/dev/null || groupadd --system "$EGRESS_USER"
install -d -m 0755 -o root -g root "$EGRESS_HOME"
if ! id "$EGRESS_USER" >/dev/null 2>&1; then
	useradd --system --gid "$EGRESS_USER" --home-dir "$EGRESS_HOME" \
		--shell /usr/sbin/nologin --password 'NP' "$EGRESS_USER"
fi
usermod --password 'NP' "$EGRESS_USER"

install -m 0644 -o root -g root "$SCRIPT_DIR/tinyproxy.conf" "$TINYPROXY_CONFIG"
install -m 0644 -o root -g root "$SCRIPT_DIR/github-domains" /etc/tinyproxy/github-domains

authorized_keys="$EGRESS_HOME/authorized_keys"
python3 - "$PUBLIC_KEY" "$authorized_keys" "$EGRESS_USER" <<'PY'
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
    raise SystemExit("控制机出站公钥必须是 Ed25519")
line = (
    'restrict,port-forwarding,permitopen="127.0.0.1:8888" '
    f'{parts[0]} {parts[1]} tsuite-github-egress\n'
)
fd, temporary_name = tempfile.mkstemp(prefix=".authorized_keys.", dir=authorized_keys_path.parent)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    handle.write(line)
    handle.flush()
    os.fsync(handle.fileno())
account = pwd.getpwnam(username)
os.chown(temporary_name, account.pw_uid, account.pw_gid)
os.chmod(temporary_name, 0o600)
os.replace(temporary_name, authorized_keys_path)
PY

cat >"$SSHD_CONFIG" <<EOF
# Managed by tsuite_deploy/control-node/github-egress.
Match User $EGRESS_USER
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    AuthorizedKeysFile $authorized_keys
    AllowTcpForwarding local
    AllowStreamLocalForwarding no
    GatewayPorts no
    PermitOpen 127.0.0.1:8888
    PermitTTY no
    PermitTunnel no
    X11Forwarding no
    AllowAgentForwarding no
    PermitUserRC no
    MaxSessions 0
Match all
EOF
chmod 0644 "$SSHD_CONFIG"
sshd -t

systemctl unmask tinyproxy.service
systemctl enable --now tinyproxy.service
systemctl restart tinyproxy.service
systemctl reload ssh.service
systemctl is-active --quiet tinyproxy.service || die "GitHub 出站代理未启动"
ss -lnt | grep -q '127.0.0.1:8888' || die "GitHub 出站代理未绑定回环地址"

INSTALL_COMMITTED=1
printf '堡垒机 GitHub 出站代理安装完成。\n'

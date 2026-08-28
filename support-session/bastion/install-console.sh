#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="/usr/local/lib/tsuite-support-console"
CONFIG_DIR="/etc/tsuite-support-console"
STATE_DIR="/var/lib/tsuite-support-console"
SERVICE_USER="tsuite-support-console"
ROUTES_FILE="/etc/caddy/tsuite-support-console-routes.caddy"

BASTION_HOST=""
GITHUB_CLIENT_ID=""
GITHUB_CLIENT_SECRET_FILE=""
GITHUB_ALLOWED_ORG="transinfosh"
GITHUB_ALLOWED_TEAM=""

die() {
	printf '错误: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
用法: sudo ./install-console.sh [选项]

必填：
  --bastion-host HOST              支持入口域名，例如 edge.trinfo.net
  --github-client-id ID            GitHub OAuth App 的 Client ID

可选：
  --github-client-secret-file FILE 从仅 root 可读文件获取 Client Secret；省略时在终端隐藏输入
  --github-allowed-org ORG         允许登录的 GitHub 组织，默认 transinfosh
  --github-allowed-team SLUG       可选：进一步限制到组织团队 slug
EOF
}

while (($#)); do
	case "$1" in
		--bastion-host) BASTION_HOST="${2:-}"; shift ;;
		--github-client-id) GITHUB_CLIENT_ID="${2:-}"; shift ;;
		--github-client-secret-file) GITHUB_CLIENT_SECRET_FILE="${2:-}"; shift ;;
		--github-allowed-org) GITHUB_ALLOWED_ORG="${2:-}"; shift ;;
		--github-allowed-team) GITHUB_ALLOWED_TEAM="${2:-}"; shift ;;
		--help | -h) usage; exit 0 ;;
		*) die "未知参数: $1" ;;
	esac
	shift
done

[[ "$EUID" -eq 0 ]] || die "请使用 sudo 运行"
[[ "$BASTION_HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || die "堡垒机域名无效"
[[ "$GITHUB_CLIENT_ID" =~ ^[A-Za-z0-9_-]{8,128}$ ]] || die "GitHub Client ID 无效"
[[ "$GITHUB_ALLOWED_ORG" =~ ^[A-Za-z0-9-]{1,100}$ ]] || die "GitHub 组织名无效"
[[ -z "$GITHUB_ALLOWED_TEAM" || "$GITHUB_ALLOWED_TEAM" =~ ^[A-Za-z0-9-]{1,100}$ ]] || die "GitHub 团队 slug 无效"
[[ -x /usr/local/sbin/tsuite-support-session ]] || die "请先安装 support-session 堡垒机模块"
[[ -f /etc/tsuite-support/config.json ]] || die "缺少 support-session 配置"
[[ -f /etc/caddy/tsuite-support.caddy ]] || die "请先使用最新版 install.sh 重装 support-session 堡垒机模块"
for command_name in caddy getent groupadd install python3 ssh-keygen systemctl useradd visudo; do
	command -v "$command_name" >/dev/null 2>&1 || die "缺少命令: $command_name"
done

if [[ -n "$GITHUB_CLIENT_SECRET_FILE" ]]; then
	[[ -f "$GITHUB_CLIENT_SECRET_FILE" ]] || die "GitHub Client Secret 文件不存在"
	secret_source="$GITHUB_CLIENT_SECRET_FILE"
else
	[[ -t 0 ]] || die "非交互执行时必须提供 --github-client-secret-file"
	read -r -s -p 'GitHub OAuth Client Secret: ' GITHUB_CLIENT_SECRET
	printf '\n'
	secret_source="$(mktemp /tmp/tsuite-support-console-secret.XXXXXX)"
	trap 'rm -f -- "$secret_source"' EXIT
	printf '%s' "$GITHUB_CLIENT_SECRET" >"$secret_source"
	unset GITHUB_CLIENT_SECRET
fi
GITHUB_CLIENT_SECRET="$(<"$secret_source")"
[[ "$GITHUB_CLIENT_SECRET" =~ ^[A-Za-z0-9_-]{16,256}$ ]] || die "GitHub Client Secret 格式无效"

getent group "$SERVICE_USER" >/dev/null || groupadd --system "$SERVICE_USER"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
	useradd --system --gid "$SERVICE_USER" --home-dir /nonexistent --shell /usr/sbin/nologin --password 'NP' "$SERVICE_USER"
fi
install -d -m 0750 -o root -g "$SERVICE_USER" "$CONFIG_DIR"
install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$STATE_DIR"
install -d -m 0755 -o root -g root "$INSTALL_ROOT"
install -m 0755 "$SCRIPT_DIR/tsuite_support_console_action.py" "$INSTALL_ROOT/tsuite-support-console-action"
install -m 0755 "$SCRIPT_DIR/../console/tsuite_support_console.py" "$INSTALL_ROOT/tsuite-support-console"
ln -sfn "$INSTALL_ROOT/tsuite-support-console-action" /usr/local/sbin/tsuite-support-console-action

operator_key="$CONFIG_DIR/operator_ed25519"
if [[ ! -f "$operator_key" ]]; then
	ssh-keygen -q -t ed25519 -N '' -C 'tsuite-support-console' -f "$operator_key"
	chmod 0600 "$operator_key"
	chown root:root "$operator_key"
fi
[[ -f "$operator_key.pub" ]] || die "控制台操作员公钥不存在"
chmod 0644 "$operator_key.pub"
chown root:root "$operator_key.pub"

python3 - "$CONFIG_DIR/config.json" "$GITHUB_CLIENT_ID" "$GITHUB_ALLOWED_ORG" "$GITHUB_ALLOWED_TEAM" "$BASTION_HOST" "$STATE_DIR" "$secret_source" <<'PY'
import json
import os
import sys

path, client_id, allowed_org, allowed_team, host, state_dir, secret_path = sys.argv[1:]
with open(secret_path, encoding="utf-8") as handle:
    client_secret = handle.read()
value = {
    "github_client_id": client_id,
    "github_client_secret": client_secret,
    "github_allowed_org": allowed_org,
    "public_url": f"https://{host}/support",
    "state_dir": state_dir,
    "listen_host": "127.0.0.1",
    "listen_port": 8765,
}
if allowed_team:
    value["github_allowed_team"] = allowed_team
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(value, handle, ensure_ascii=False, sort_keys=True)
    handle.write("\n")
os.chmod(temporary, 0o640)
os.replace(temporary, path)
PY
chown root:"$SERVICE_USER" "$CONFIG_DIR/config.json"
unset GITHUB_CLIENT_SECRET

cat >/etc/sudoers.d/tsuite-support-console <<EOF
$SERVICE_USER ALL=(root) NOPASSWD: /usr/local/sbin/tsuite-support-console-action create *
$SERVICE_USER ALL=(root) NOPASSWD: /usr/local/sbin/tsuite-support-console-action show *
$SERVICE_USER ALL=(root) NOPASSWD: /usr/local/sbin/tsuite-support-console-action close *
$SERVICE_USER ALL=(root) NOPASSWD: /usr/local/sbin/tsuite-support-console-action list
EOF
chmod 0440 /etc/sudoers.d/tsuite-support-console
visudo -cf /etc/sudoers.d/tsuite-support-console >/dev/null || die "控制台 sudoers 配置校验失败"

cat >"$ROUTES_FILE" <<'EOF'
# Managed by tsuite_deploy/support-session.
handle_path /support/* {
    reverse_proxy 127.0.0.1:8765
}
EOF
chmod 0644 "$ROUTES_FILE"
grep -Fqx "    import $ROUTES_FILE" /etc/caddy/tsuite-support.caddy || \
	die "请先使用最新版 install.sh 重装 support-session 堡垒机模块"
caddy validate --config /etc/caddy/Caddyfile >/dev/null || die "Caddy 控制台配置校验失败"

cat >/etc/systemd/system/tsuite-support-console.service <<EOF
[Unit]
Description=TSuite Support Management Console
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=/usr/bin/python3 $INSTALL_ROOT/tsuite-support-console
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$STATE_DIR
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tsuite-support-console.service
systemctl reload caddy
systemctl is-active --quiet tsuite-support-console.service || die "控制台服务未能启动"

printf 'support-session GitHub 管理页面安装完成。\n'
printf '访问地址：https://%s/support/\n' "$BASTION_HOST"
printf 'GitHub OAuth Callback URL：https://%s/support/auth/github/callback\n' "$BASTION_HOST"

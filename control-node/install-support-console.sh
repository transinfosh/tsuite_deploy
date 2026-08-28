#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_ROOT="/usr/local/lib/tsuite-support-console"
CONFIG_DIR="/etc/tsuite-support-console"
STATE_DIR="/var/lib/tsuite-support-console"
SERVICE_USER="tsuite-support-console"
SERVICE_GROUP="tsuite-support-console"
BROKER_USER="tsuite-support-operator"
BROKER_STATE_DIR="/var/lib/tsuite-support-operator"

GITHUB_CLIENT_ID=""
GITHUB_CLIENT_SECRET_FILE=""
GITHUB_ALLOWED_ORG="transinfosh"
GITHUB_ALLOWED_TEAM=""
PUBLIC_HOST="edge.trinfo.net"

die() {
	printf '错误: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
用法: sudo ./install-support-console.sh [选项]

必填：
  --github-client-id ID            GitHub OAuth App Client ID

可选：
  --github-client-secret-file FILE 仅 root 可读、只包含 Client Secret 的文件；升级时可沿用现有配置
  --github-allowed-org ORG         允许登录的组织，默认 transinfosh
  --github-allowed-team SLUG       可选：限制到组织团队 slug
  --public-host HOST               公网域名，默认 edge.trinfo.net
EOF
}

while (($#)); do
	case "$1" in
		--github-client-id) GITHUB_CLIENT_ID="${2:-}"; shift ;;
		--github-client-secret-file) GITHUB_CLIENT_SECRET_FILE="${2:-}"; shift ;;
		--github-allowed-org) GITHUB_ALLOWED_ORG="${2:-}"; shift ;;
		--github-allowed-team) GITHUB_ALLOWED_TEAM="${2:-}"; shift ;;
		--public-host) PUBLIC_HOST="${2:-}"; shift ;;
		--help | -h) usage; exit 0 ;;
		*) die "未知参数: $1" ;;
	esac
	shift
done

[[ "$EUID" -eq 0 ]] || die "请使用 sudo 运行"
[[ "$GITHUB_CLIENT_ID" =~ ^[A-Za-z0-9_-]{8,128}$ ]] || die "GitHub Client ID 无效"
if [[ -n "$GITHUB_CLIENT_SECRET_FILE" ]]; then
	[[ -f "$GITHUB_CLIENT_SECRET_FILE" ]] || die "GitHub Client Secret 文件不存在"
else
	[[ -f "$CONFIG_DIR/config.json" ]] || \
		die "首次安装必须提供 --github-client-secret-file"
fi
[[ "$GITHUB_ALLOWED_ORG" =~ ^[A-Za-z0-9-]{1,100}$ ]] || die "GitHub 组织名无效"
[[ -z "$GITHUB_ALLOWED_TEAM" || "$GITHUB_ALLOWED_TEAM" =~ ^[A-Za-z0-9-]{1,100}$ ]] || die "GitHub 团队 slug 无效"
[[ "$PUBLIC_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "公网域名无效"
[[ -f /etc/tsuite-support-control/action.json ]] || die "请先运行 prepare-support-access.sh"
[[ -x /usr/local/bin/tsuite-support-console-action ]] || die "缺少控制台远程操作程序"
id "$BROKER_USER" >/dev/null 2>&1 || die "缺少支持会话 broker 用户"
for command_name in curl gpasswd getent groupadd install python3 ss sudo systemctl useradd usermod; do
	command -v "$command_name" >/dev/null 2>&1 || die "缺少命令: $command_name"
done

getent group "$SERVICE_GROUP" >/dev/null || groupadd --system "$SERVICE_GROUP"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
	useradd --system --gid "$SERVICE_GROUP" --home-dir /nonexistent \
		--shell /usr/sbin/nologin --password 'NP' "$SERVICE_USER"
fi
usermod --gid "$SERVICE_GROUP" "$SERVICE_USER"
if id -nG "$SERVICE_USER" | tr ' ' '\n' | grep -Fxq "$BROKER_USER"; then
	gpasswd -d "$SERVICE_USER" "$BROKER_USER" >/dev/null
fi
if id -nG "$SERVICE_USER" | tr ' ' '\n' | grep -Fxq tsuite-deploy; then
	gpasswd -d "$SERVICE_USER" tsuite-deploy >/dev/null
fi
install -d -m 0755 -o root -g root "$INSTALL_ROOT"
install -d -m 0750 -o root -g "$SERVICE_GROUP" "$CONFIG_DIR"
install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$STATE_DIR"
install -m 0755 -o root -g root \
	"$REPO_ROOT/support-session/console/tsuite_support_console.py" \
	"$INSTALL_ROOT/tsuite-support-console"

config_temporary="$(mktemp "$CONFIG_DIR/.config.json.XXXXXX")"
trap 'rm -f -- "$config_temporary"' EXIT
python3 - "$config_temporary" "$GITHUB_CLIENT_ID" "$GITHUB_CLIENT_SECRET_FILE" \
	"$GITHUB_ALLOWED_ORG" "$GITHUB_ALLOWED_TEAM" "$PUBLIC_HOST" "$STATE_DIR" \
	"$CONFIG_DIR/config.json" <<'PY'
import json
import pathlib
import sys

path, client_id, secret_path, allowed_org, allowed_team, host, state_dir, existing_path = sys.argv[1:]
if secret_path:
    secret = pathlib.Path(secret_path).read_text(encoding="utf-8")
else:
    with pathlib.Path(existing_path).open(encoding="utf-8") as handle:
        existing = json.load(handle)
    secret = existing.get("github_client_secret", "")
if not isinstance(secret, str) or not secret or "\n" in secret:
    raise SystemExit("GitHub Client Secret 文件格式无效")
value = {
    "github_client_id": client_id,
    "github_client_secret": secret,
    "github_allowed_org": allowed_org,
    "public_url": f"https://{host}/support",
    "state_dir": state_dir,
    "listen_host": "127.0.0.1",
    "listen_port": 8765,
}
if allowed_team:
    value["github_allowed_team"] = allowed_team
pathlib.Path(path).write_text(json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
PY
install -m 0640 -o root -g "$SERVICE_GROUP" "$config_temporary" "$CONFIG_DIR/config.json"
rm -f "$config_temporary"
trap - EXIT

cat >/etc/systemd/system/tsuite-support-console.service <<EOF
[Unit]
Description=TSuite GitHub support management console
After=network-online.target tsuite-frpc.service
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
ExecStartPre=/usr/bin/sudo -n -u $BROKER_USER /usr/local/bin/tsuite-support-console-action list
ExecStart=/usr/bin/python3 $INSTALL_ROOT/tsuite-support-console
Environment=HTTPS_PROXY=http://127.0.0.1:18080
Environment=HTTP_PROXY=http://127.0.0.1:18080
Restart=on-failure
RestartSec=3
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
LockPersonality=yes
SystemCallArchitectures=native
ReadOnlyPaths=$CONFIG_DIR
ReadWritePaths=$STATE_DIR $BROKER_STATE_DIR
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

# 该服务只通过精确 sudoers 规则调用 broker；它不能读取 broker 私钥，也不能调用 ssh/run/force-close。
sudo -n -u "$BROKER_USER" /usr/local/bin/tsuite-support-console-action self-test >/dev/null || \
	die "支持会话 broker 自检失败"

# 新 broker 通道验证成功后移除旧页面曾可读取的共享/固定私钥副本。
rm -f -- \
	"$CONFIG_DIR/action.json" \
	"$CONFIG_DIR/bridge_ed25519" "$CONFIG_DIR/bridge_ed25519.pub" \
	"$CONFIG_DIR/edge_operator_ed25519" "$CONFIG_DIR/edge_operator_ed25519.pub" \
	"$CONFIG_DIR/operator_ed25519" "$CONFIG_DIR/operator_ed25519.pub" \
	"$CONFIG_DIR/known_hosts"

systemctl daemon-reload
systemctl enable --now tsuite-support-console.service
systemctl restart tsuite-support-console.service nginx.service
systemctl is-active --quiet tsuite-support-console.service || die "支持管理页面未启动"
for _ in {1..20}; do
	ss -lnt | grep -q '127.0.0.1:8765' && break
	sleep 0.25
done
ss -lnt | grep -q '127.0.0.1:8765' || die "支持管理页面未监听本机端口"
http_status="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/support/)"
[[ "$http_status" == "401" ]] || die "本机支持页面健康检查失败: HTTP $http_status"

printf 'GitHub 支持管理页面安装完成：https://%s/support/\n' "$PUBLIC_HOST"

#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRPC_BINARY=""
FRP_TOKEN_FILE=""
FRP_SERVER="edge.trinfo.net"
FRP_PORT="7000"
CONTROL_USER="tsuite-deploy"
CONTROL_GROUP="tsuite-deploy"
OPERATOR_USER="adam"

die() {
	printf '错误: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
用法: sudo ./install.sh --frpc-binary FILE --frp-token-file FILE [选项]

必填：
  --frpc-binary FILE       已校验来源的 frpc 可执行文件
  --frp-token-file FILE    仅 root 可读、只包含 FRP Token 的文件

可选：
  --frp-server HOST        FRPS 域名，默认 edge.trinfo.net
  --frp-port PORT          FRPS 端口，默认 7000
  --operator-user USER     日常部署账号，默认 adam
EOF
}

while (($#)); do
	case "$1" in
		--frpc-binary) FRPC_BINARY="${2:-}"; shift ;;
		--frp-token-file) FRP_TOKEN_FILE="${2:-}"; shift ;;
		--frp-server) FRP_SERVER="${2:-}"; shift ;;
		--frp-port) FRP_PORT="${2:-}"; shift ;;
		--operator-user) OPERATOR_USER="${2:-}"; shift ;;
		--help | -h) usage; exit 0 ;;
		*) die "未知参数: $1" ;;
	esac
	shift
done

[[ "$EUID" -eq 0 ]] || die "请使用 sudo 运行"
[[ -x "$FRPC_BINARY" ]] || die "frpc 文件不存在或不可执行"
[[ -f "$FRP_TOKEN_FILE" ]] || die "FRP Token 文件不存在"
[[ "$FRP_SERVER" =~ ^[A-Za-z0-9.-]+$ ]] || die "FRPS 域名无效"
[[ "$FRP_PORT" =~ ^[0-9]+$ ]] && ((FRP_PORT >= 1 && FRP_PORT <= 65535)) || die "FRPS 端口无效"
[[ "$OPERATOR_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "部署账号无效"
id "$OPERATOR_USER" >/dev/null 2>&1 || die "部署账号不存在: $OPERATOR_USER"
for command_name in curl getent groupadd install nginx python3 systemctl useradd usermod; do
	command -v "$command_name" >/dev/null 2>&1 || die "缺少命令: $command_name"
done

getent group "$CONTROL_GROUP" >/dev/null || groupadd --system "$CONTROL_GROUP"
if ! id "$CONTROL_USER" >/dev/null 2>&1; then
	useradd --system --gid "$CONTROL_GROUP" --home-dir /var/lib/tsuite-deploy \
		--shell /usr/sbin/nologin --password 'NP' "$CONTROL_USER"
fi
usermod -aG "$CONTROL_GROUP" "$OPERATOR_USER"
id www-data >/dev/null 2>&1 && usermod -aG "$CONTROL_GROUP" www-data

install -d -m 0750 -o root -g "$CONTROL_GROUP" /etc/tsuite-deploy /etc/frp
install -d -m 2770 -o "$CONTROL_USER" -g "$CONTROL_GROUP" \
	/var/lib/tsuite-deploy /srv/tsuite-deploy /srv/tsuite-deploy/files \
	/srv/tsuite-deploy/repositories /srv/tsuite-deploy/logs /srv/tsuite-deploy/backups
install -m 0755 "$FRPC_BINARY" /usr/local/bin/frpc

token="$(<"$FRP_TOKEN_FILE")"
[[ -n "$token" && "$token" != *$'\n'* ]] || die "FRP Token 文件格式无效"
config_temporary="$(mktemp /etc/frp/.frpc.toml.XXXXXX)"
trap 'rm -f -- "$config_temporary"' EXIT
python3 - "$config_temporary" "$FRP_SERVER" "$FRP_PORT" "$FRP_TOKEN_FILE" <<'PY'
import json
import pathlib
import sys

path, server, port, token_path = sys.argv[1:]
token = pathlib.Path(token_path).read_text(encoding="utf-8")
content = f'''serverAddr = {json.dumps(server)}
serverPort = {int(port)}

auth.method = "token"
auth.token = {json.dumps(token)}

transport.tls.enable = true

[[proxies]]
name = "tsuite-deploy-control-web"
type = "http"
localIP = "127.0.0.1"
localPort = 8081
customDomains = ["edge.trinfo.net"]
'''
pathlib.Path(path).write_text(content, encoding="utf-8")
PY
chmod 0600 "$config_temporary"
chown root:root "$config_temporary"
install -m 0640 -o root -g "$CONTROL_GROUP" "$config_temporary" /etc/frp/frpc.toml
rm -f "$config_temporary"
trap - EXIT

install -m 0644 -o root -g root "$SCRIPT_DIR/nginx.conf" /etc/nginx/sites-available/tsuite-control
ln -sfn /etc/nginx/sites-available/tsuite-control /etc/nginx/sites-enabled/tsuite-control
rm -f /etc/nginx/sites-enabled/default
nginx -t

cat >/etc/systemd/system/tsuite-frpc.service <<'EOF'
[Unit]
Description=TSuite deployment control FRP client
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
User=tsuite-deploy
Group=tsuite-deploy
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc.toml
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadOnlyPaths=/etc/frp/frpc.toml

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now nginx.service tsuite-frpc.service
systemctl restart nginx.service tsuite-frpc.service
systemctl is-active --quiet nginx.service || die "Nginx 未启动"
systemctl is-active --quiet tsuite-frpc.service || die "FRPC 未启动"
curl -fsS http://127.0.0.1:8081/_tsuite-control-health >/dev/null || die "控制机 HTTP 健康检查失败"

printf '部署控制机基础模块安装完成。\n'
printf 'FRPS：%s:%s\n' "$FRP_SERVER" "$FRP_PORT"
printf '文件目录：/srv/tsuite-deploy/files\n'

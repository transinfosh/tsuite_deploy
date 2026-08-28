#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDENTITY_FILE=""
KNOWN_HOSTS_FILE=""
OPERATOR_USER="adam"
SERVICE_USER="tsuite-deploy"
EGRESS_HOST="edge.trinfo.net"

die() {
	printf '错误: %s\n' "$*" >&2
	exit 1
}

while (($#)); do
	case "$1" in
		--identity-file) IDENTITY_FILE="${2:-}"; shift ;;
		--known-hosts-file) KNOWN_HOSTS_FILE="${2:-}"; shift ;;
		--operator-user) OPERATOR_USER="${2:-}"; shift ;;
		--egress-host) EGRESS_HOST="${2:-}"; shift ;;
		*) die "未知参数: $1" ;;
	esac
	shift
done

[[ "$EUID" -eq 0 ]] || die "请使用 sudo 运行"
[[ -f "$IDENTITY_FILE" ]] || die "缺少 GitHub 出站 SSH identity"
[[ -f "$KNOWN_HOSTS_FILE" ]] || die "缺少 GitHub 出口机 known_hosts"
id "$SERVICE_USER" >/dev/null 2>&1 || die "请先安装部署控制机基础模块"
id "$OPERATOR_USER" >/dev/null 2>&1 || die "部署账号不存在"

install -d -m 0750 -o root -g tsuite-deploy /etc/tsuite-github-egress
install -m 0640 -o root -g tsuite-deploy "$IDENTITY_FILE" /etc/tsuite-github-egress/id_ed25519
install -m 0644 -o root -g tsuite-deploy "$KNOWN_HOSTS_FILE" /etc/tsuite-github-egress/known_hosts
install -m 0755 -o root -g root "$SCRIPT_DIR/gh-wrapper" /usr/local/bin/gh

cat >/etc/systemd/system/tsuite-github-egress.service <<EOF
[Unit]
Description=Restricted GitHub HTTPS egress for TSuite deployment control
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=tsuite-deploy
Group=tsuite-deploy
ExecStart=/usr/bin/ssh -F none -N -L 127.0.0.1:18080:127.0.0.1:8888 -i /etc/tsuite-github-egress/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/tsuite-github-egress/known_hosts -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 tsuite-github-egress@$EGRESS_HOST
Restart=always
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadOnlyPaths=/etc/tsuite-github-egress

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tsuite-github-egress.service
systemctl restart tsuite-github-egress.service
systemctl is-active --quiet tsuite-github-egress.service || die "GitHub 出站 SSH 通道未启动"
for _ in {1..20}; do
	ss -lnt | grep -q '127.0.0.1:18080' && break
	sleep 0.25
done
ss -lnt | grep -q '127.0.0.1:18080' || die "GitHub 出站 SSH 通道未监听本机端口"
HTTPS_PROXY=http://127.0.0.1:18080 curl -fsS --connect-timeout 5 --max-time 15 \
	https://api.github.com/zen >/dev/null || die "GitHub 出站代理验证失败"
sudo -u "$OPERATOR_USER" git config --global http.https://github.com.proxy http://127.0.0.1:18080

printf '控制机 GitHub 出站通道安装完成。\n'

#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_REF="main"
DEFAULT_INSTALL_PATH="/usr/local/sbin/tsuite-deploy"
LEGACY_INSTALL_PATH="/usr/local/sbin/tsuie-deploy"
REPOSITORY_RAW_URL="https://raw.githubusercontent.com/transinfosh/tsuite_deploy"

REF="${TSUITE_DEPLOY_REF:-${TSUIE_DEPLOY_REF:-$DEFAULT_REF}}"
INSTALL_PATH="${TSUITE_DEPLOY_INSTALL_PATH:-${TSUIE_DEPLOY_INSTALL_PATH:-$DEFAULT_INSTALL_PATH}}"

die() {
	printf '错误: %s\n' "$*" >&2
	exit 1
}

[[ "$EUID" -eq 0 ]] || die "请使用 sudo 运行安装脚本"
[[ "$REF" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*$ ]] || die "版本格式无效: $REF"
[[ "$INSTALL_PATH" == /* ]] || die "安装路径必须是绝对路径"
command -v curl >/dev/null 2>&1 || die "未找到 curl，请先安装 curl"

temporary_script="$(mktemp /tmp/tsuite-deploy.XXXXXX)"
trap 'rm -f -- "$temporary_script"' EXIT

printf '正在下载 tsuite_deploy（%s）...\n' "$REF"
curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
	--retry 3 \
	"$REPOSITORY_RAW_URL/$REF/deploy.sh" \
	--output "$temporary_script"

bash -n "$temporary_script" || die "下载的部署脚本未通过 Bash 语法检查"
install -D -m 0755 "$temporary_script" "$INSTALL_PATH"

if [[ "$INSTALL_PATH" == "$DEFAULT_INSTALL_PATH" && -e "$LEGACY_INSTALL_PATH" ]]; then
	rm -f "$LEGACY_INSTALL_PATH"
fi

printf '安装完成: %s\n' "$INSTALL_PATH"
printf '运行部署: sudo %q\n' "$INSTALL_PATH"

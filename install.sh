#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_REF="main"
DEFAULT_INSTALL_PATH="/usr/local/sbin/tsuite-deploy"
LEGACY_INSTALL_PATH="/usr/local/sbin/tsuie-deploy"
REPOSITORY_ARCHIVE_URL="https://codeload.github.com/transinfosh/tsuite_deploy/tar.gz"

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

temporary_dir="$(mktemp -d /tmp/tsuite-deploy.XXXXXX)"
temporary_archive="$temporary_dir/source.tar.gz"
temporary_script=""
trap 'rm -rf -- "$temporary_dir"' EXIT
cache_buster="$(date +%s)"

printf '正在下载 tsuite_deploy（%s）...\n' "$REF"
curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
	--retry 3 \
	"$REPOSITORY_ARCHIVE_URL/$REF?cache_buster=$cache_buster" \
	--output "$temporary_archive"
tar -xzf "$temporary_archive" -C "$temporary_dir"
temporary_script="$(find "$temporary_dir" -type f -path '*/single-node/deploy.sh' -print -quit)"
if [[ ! -f "$temporary_script" ]]; then
	# 兼容 TSUITE_DEPLOY_REF 指向目录调整前的历史 Tag 或提交。
	temporary_script="$(find "$temporary_dir" -mindepth 2 -maxdepth 2 -type f -name deploy.sh -print -quit)"
fi
[[ -f "$temporary_script" ]] || die "下载的源码归档不包含单机部署脚本"

bash -n "$temporary_script" || die "下载的部署脚本未通过 Bash 语法检查"
install -D -m 0755 "$temporary_script" "$INSTALL_PATH"

if [[ "$INSTALL_PATH" == "$DEFAULT_INSTALL_PATH" && -e "$LEGACY_INSTALL_PATH" ]]; then
	rm -f "$LEGACY_INSTALL_PATH"
fi

printf '安装完成: %s\n' "$INSTALL_PATH"
printf '运行部署: sudo %q\n' "$INSTALL_PATH"

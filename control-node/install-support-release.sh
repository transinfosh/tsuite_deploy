#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/support-release.env"

[[ "$TSUITE_SUPPORT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf '支持工具版本无效\n' >&2; exit 1; }
[[ "$TSUITE_SUPPORT_SHA256" =~ ^[a-f0-9]{64}$ ]] || { printf '支持工具 SHA-256 无效\n' >&2; exit 1; }
entrypoint="${1:-}"
case "$entrypoint" in
	control/prepare-support-access.sh | control/install-support-console.sh) ;;
	*) printf '未知支持工具安装入口\n' >&2; exit 1 ;;
esac
shift

work_dir="$(mktemp -d /tmp/tsuite-support-release.XXXXXX)"
cleanup() {
	find "$work_dir" -mindepth 1 -delete
	rmdir "$work_dir"
}
trap cleanup EXIT
archive="$work_dir/source.tar.gz"
if [[ -n "${TSUITE_SUPPORT_ARCHIVE:-}" ]]; then
	cp -- "$TSUITE_SUPPORT_ARCHIVE" "$archive"
else
	curl --fail --silent --show-error --location --retry 3 --proto '=https' --proto-redir '=https' --tlsv1.2 \
		--output "$archive" \
		"https://github.com/transinfosh/tsuite-support/releases/download/v$TSUITE_SUPPORT_VERSION/tsuite-support-v$TSUITE_SUPPORT_VERSION.tar.gz"
fi
printf '%s  %s\n' "$TSUITE_SUPPORT_SHA256" "$archive" | sha256sum --check --status || {
	printf '支持工具归档 SHA-256 校验失败，停止安装\n' >&2
	exit 1
}
tar --extract --gzip --file "$archive" --directory "$work_dir" --no-same-owner --no-same-permissions
bash "$work_dir/tsuite-support-v$TSUITE_SUPPORT_VERSION/$entrypoint" "$@"

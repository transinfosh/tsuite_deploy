#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
multi_node_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$multi_node_root/.." && pwd)"
bench_root="${TAI_BENCH_ROOT:-$repo_root/../frappe-bench}"
frappe_docker_root="${TAI_FRAPPE_DOCKER_ROOT:-$repo_root/../frappe-develop-docker}"
artifact_dir="$multi_node_root/ansible/artifacts"
artifact_path="$artifact_dir/tai-source-current.tar.gz"
checksum_path="$artifact_path.sha256"

if [[ ! -d "$bench_root/apps/tai" || ! -d "$bench_root/services/tai-service" ]]; then
	printf '错误: 未找到 tAI Bench，当前路径: %s\n' "$bench_root" >&2
	printf '可通过 TAI_BENCH_ROOT=/absolute/path 指定。\n' >&2
	exit 1
fi

if [[ ! -f "$frappe_docker_root/compose.yaml" || ! -d "$frappe_docker_root/resources/core" ]]; then
	printf '错误: 未找到 frappe_docker，当前路径: %s\n' "$frappe_docker_root" >&2
	printf '可通过 TAI_FRAPPE_DOCKER_ROOT=/absolute/path 指定。\n' >&2
	exit 1
fi

mkdir -p "$artifact_dir"
tmp_dir="$(mktemp -d /tmp/tai-source-bundle.XXXXXX)"
trap 'rm -rf -- "$tmp_dir"' EXIT

manifest="$tmp_dir/snapshot-manifest.txt"
{
	printf 'lock_state=unlocked-internal-demo\n'
	printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'bench_root=%s\n' "$bench_root"
	printf 'frappe_docker_root=%s\n' "$frappe_docker_root"
	for path in \
		apps/frappe apps/frappe_ext apps/tbi apps/tai apps/tai_control \
		services/tbi-engine services/tai-service services/tai-auth packages/tai-chat packages/transinfo-ui; do
		printf '\n[%s]\n' "$path"
		git -C "$bench_root/$path" rev-parse HEAD 2>/dev/null || printf 'git_head=unavailable\n'
		git -C "$bench_root/$path" status --short 2>/dev/null || true
	done
	printf '\n[frappe_docker]\n'
	git -C "$frappe_docker_root" rev-parse HEAD 2>/dev/null || printf 'git_head=unavailable\n'
	git -C "$frappe_docker_root" status --short 2>/dev/null || true
} >"$manifest"

mkdir -p "$tmp_dir/frappe_docker"
tar \
	--exclude='.git' \
	--exclude='.venv' \
	--exclude='node_modules' \
	--exclude='__pycache__' \
	-C "$frappe_docker_root" \
	-cf - . | tar -C "$tmp_dir/frappe_docker" -xf -

tmp_archive="$tmp_dir/tai-source.tar.gz"
tar \
	--exclude='.git' \
	--exclude='.venv' \
	--exclude='.venv-*' \
	--exclude='node_modules' \
	--exclude='__pycache__' \
	--exclude='.ruff_cache' \
	--exclude='*.pyc' \
	-C "$bench_root" \
	-czf "$tmp_archive" \
	apps/frappe \
	apps/frappe_ext \
	apps/tbi \
	apps/tai \
	apps/tai_control \
	services/tbi-engine \
	services/tai-service \
	services/tai-auth \
	packages/tai-chat \
	packages/transinfo-ui \
	-C "$tmp_dir" frappe_docker snapshot-manifest.txt

install -m 0644 "$tmp_archive" "$artifact_path"
(
	cd "$artifact_dir"
	sha256sum "$(basename "$artifact_path")" >"$(basename "$checksum_path")"
)

printf '源码快照已生成：%s\n' "$artifact_path"
printf 'SHA256：%s\n' "$(cut -d' ' -f1 "$checksum_path")"

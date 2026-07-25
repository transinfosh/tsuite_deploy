#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$repo_root/deploy.sh"
"$repo_root/deploy.sh" --help | grep -q -- "--dry-run"

if command -v shellcheck >/dev/null 2>&1; then
	shellcheck "$repo_root/deploy.sh"
fi

fixture_dir="$(mktemp -d /tmp/frappe-deploy-test.XXXXXX)"
trap 'rm -rf -- "$fixture_dir"' EXIT

# 载入函数但不执行脚本入口，验证生成文件可以被 YAML 解析。
# shellcheck disable=SC1090
source <(sed '$d' "$repo_root/deploy.sh")
export DEPLOY_DIR="$fixture_dir"
export IMAGE_REPOSITORY="ghcr.io/transinfosh/project_management"
export IMAGE_TAG="test"
export DB_PASSWORD="1234567890abcdef"
export HTTP_PORT="8080"
export DB_MODE="container"
export DB_PORT="5432"
export BIND_ADDRESS="127.0.0.1"
export DOCKER_SUBNET="172.30.0.0/24"
export PROXY_ENABLED=false
export SITE_NAME="project.localhost"
export FRAPPE_DOCKER_COMMIT="test"

write_env_file
write_generated_compose
write_proxy_compose
write_state

python3 - "$fixture_dir/compose.generated.yaml" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as compose_file:
    document = yaml.safe_load(compose_file)

assert document["services"]["frontend"]["ports"] == ["127.0.0.1:8080:8080"]
assert document["services"]["configurator"]["environment"]["DB_HOST"] == "db"
assert document["networks"]["default"]["ipam"]["config"][0]["subnet"] == "172.30.0.0/24"
PY

grep -q '^CUSTOM_IMAGE=ghcr.io/transinfosh/project_management$' "$fixture_dir/.env"
grep -q '^STATE_DB_MODE=container$' "$fixture_dir/deployment.state"

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$repo_root/deploy.sh"
bash -n "$repo_root/install.sh"
"$repo_root/deploy.sh" --help | grep -q -- "--dry-run"
grep -q 'GitHub 源码归档' "$repo_root/deploy.sh"
grep -q 'https://codeload.github.com/' "$repo_root/deploy.sh"
grep -q 'find_adopt_source_backend()' "$repo_root/deploy.sh"
grep -q 'docker exec "$backend_container"' "$repo_root/deploy.sh"
grep -q 'label=com.docker.compose.project=$ADOPT_SOURCE_PROJECT' "$repo_root/deploy.sh"
grep -q 'STATE_ADOPT_SOURCE_COMPOSE' "$repo_root/deploy.sh"
grep -q 'EXISTING_ADOPT_SOURCE_COMPOSE' "$repo_root/deploy.sh"
grep -q 'read_apt_proxy_value()' "$repo_root/deploy.sh"
grep -q 'read_docker_no_proxy_value()' "$repo_root/deploy.sh"

if command -v shellcheck >/dev/null 2>&1; then
	shellcheck "$repo_root/deploy.sh" "$repo_root/install.sh"
fi

fixture_dir="$(mktemp -d /tmp/tsuie-deploy-test.XXXXXX)"
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
export DB_ADMIN_USER="postgres"
export BIND_ADDRESS="127.0.0.1"
export DOCKER_SUBNET="172.30.0.0/24"
export PROXY_ENABLED=false
export SITE_NAME="project.localhost"
export FRAPPE_DOCKER_COMMIT="test"
# 由动态载入的 write_state 使用。
# shellcheck disable=SC2034
APP_LIST=(project_management)

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
grep -q '^PULL_POLICY=missing$' "$fixture_dir/.env"
grep -q '^STATE_DB_MODE=container$' "$fixture_dir/deployment.state"
grep -q '^STATE_IMAGE=ghcr.io/transinfosh/project_management:test$' "$fixture_dir/deployment.state"
grep -q '^STATE_FRAPPE_DOCKER_COMMIT=test$' "$fixture_dir/deployment.state"

EXISTING_DEPLOYMENT=false
PREVIOUS_IMAGE=""
PREVIOUS_FRAPPE_DOCKER_COMMIT=""
EXISTING_DB_PASSWORD=""
load_existing_deployment >/dev/null
"$EXISTING_DEPLOYMENT"
[[ "$PREVIOUS_IMAGE" == "ghcr.io/transinfosh/project_management:test" ]]
[[ "$PREVIOUS_FRAPPE_DOCKER_COMMIT" == "test" ]]
[[ "$EXISTING_DB_PASSWORD" == "1234567890abcdef" ]]

export DRY_RUN=false
create_upgrade_snapshot
[[ -f "$ROLLBACK_DIR/.env" ]]
[[ -f "$ROLLBACK_DIR/deployment.state" ]]
[[ "$(cat "$ROLLBACK_DIR/frappe_docker.commit")" == "test" ]]

validate_private_subnet "172.30.0.0/24"
if validate_private_subnet "172.30.0.1/24"; then
	echo "未拒绝非网络地址的 Docker 子网" >&2
	exit 1
fi
if validate_private_subnet "8.8.8.0/24"; then
	echo "未拒绝公网 Docker 子网" >&2
	exit 1
fi

database_password_is_valid "postgres"
if database_password_is_valid ""; then
	echo "错误地接受了空数据库密码" >&2
	exit 1
fi
prompt_database_password RETRIED_PASSWORD "测试数据库密码" "" \
	<<< $'\npostgres' >/dev/null 2>&1
[[ "$RETRIED_PASSWORD" == "postgres" ]]

#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source <(sed '$d' "$repo_root/single-node/deploy.sh")
fixture="$(mktemp -d /tmp/tsuite-adopt-test.XXXXXX)"
trap 'find "$fixture" -mindepth 1 -delete; rmdir "$fixture"' EXIT

DEPLOY_DIR="$fixture"
IMAGE_REPOSITORY="ghcr.io/transinfosh/srm"
IMAGE_TAG="0.1.7"
DB_PASSWORD=""
HTTP_PORT="8080"
DB_MODE="adopt"
DB_PORT="5432"
DB_ADMIN_USER=""
BIND_ADDRESS="127.0.0.1"
DOCKER_SUBNET="172.30.0.0/24"
PROXY_ENABLED=false
SITE_NAME="srm.dtaut.com"
FRAPPE_DOCKER_COMMIT="test"
APP_LIST=(srm)
ADOPT_SOURCE_COMPOSE="/home/customer/srm-compose.yml"
ADOPT_SOURCE_VOLUME="frappe_docker_sites"
ADOPT_TARGET_VOLUME="tsuite-srm-dtaut-com-sites"
ADOPT_DB_HOST="192.168.10.222"
ADOPT_NETWORK_NAME="frappe_docker_default"

write_env_file
write_generated_compose
write_state
grep -Fxq 'ERPNEXT_VERSION=' "$fixture/.env"

python3 - "$fixture" <<'PY'
import pathlib
import sys

import yaml

root = pathlib.Path(sys.argv[1])
compose = yaml.safe_load((root / "compose.generated.yaml").read_text(encoding="utf-8"))
assert compose["networks"]["default"] == {
    "ipam": {"config": [{"subnet": "172.30.0.0/24"}]},
}
assert compose["volumes"]["sites"] == {
    "external": True,
    "name": "tsuite-srm-dtaut-com-sites",
}
state = (root / "deployment.state").read_text(encoding="utf-8")
assert "STATE_DB_MODE=adopt\n" in state
assert "STATE_ADOPT_DB_HOST=192.168.10.222\n" in state
assert "STATE_ADOPT_NETWORK_NAME=frappe_docker_default\n" in state
PY

# 模拟升级失败后 deployment.inputs 被新一次交互写成 container，而最后成功状态仍是 adopt。
# 重试必须以成功状态为准，继续复用外部 volume 和宿主机数据库。
# 旧 network 只保留为首次接管备份信息，新 Compose 的运行网络由 tsuite-deploy 管理。
IMAGE="ghcr.io/transinfosh/srm:0.1.8"
APPS_INPUT="srm"
FRAPPE_DOCKER_REPO="https://github.com/frappe/frappe_docker.git"
FRAPPE_DOCKER_REF="main"
DB_MODE="container"
DB_ADMIN_USER="postgres"
write_deployment_inputs

# shellcheck disable=SC2317
prompt() {
	local variable_name="$1"
	local default_value="${3:-}"
	if [[ "$variable_name" == "DEPLOY_DIR" ]]; then
		printf -v "$variable_name" '%s' "$fixture"
	else
		printf -v "$variable_name" '%s' "$default_value"
	fi
}
# shellcheck disable=SC2317
confirm() {
	return 1
}
EXISTING_DEPLOYMENT=false
collect_deployment_settings >/dev/null
[[ "$DB_MODE" == "adopt" ]]
[[ "$ADOPT_TARGET_VOLUME" == "tsuite-srm-dtaut-com-sites" ]]
[[ "$ADOPT_DB_HOST" == "192.168.10.222" ]]
[[ "$ADOPT_NETWORK_NAME" == "frappe_docker_default" ]]

mkdir -p "$fixture/source-volume/srm.dtaut.com"
cat >"$fixture/source-volume/srm.dtaut.com/site_config.json" <<'JSON'
{
  "db_host": "192.168.10.222",
  "db_port": 5432,
  "db_name": "srm",
  "db_user": "srm",
  "db_password": "database-password"
}
JSON
ADOPT_SOURCE_VOLUME="frappe_docker_sites"
COMPATIBLE_IMAGE_USED=false
# shellcheck disable=SC2317
jq() {
	case "$2" in
		'.db_name // empty') printf 'srm\n' ;;
		'.db_host // empty') printf '192.168.10.222\n' ;;
		'.db_port // empty') printf '5432\n' ;;
		'.db_user // empty') printf 'srm\n' ;;
		'.db_password // empty') printf 'database-password\n' ;;
		*) printf '未预期的 jq 查询: %s\n' "$2" >&2; return 1 ;;
	esac
}
# shellcheck disable=SC2317
docker() {
	case "$1 $2" in
		"volume inspect") printf '%s\n' "$fixture/source-volume" ;;
		"exec -e") printf '180006\n' ;;
		"run --rm")
			local argument
			for argument in "$@"; do
				if [[ "$argument" == "postgres:18" ]]; then
					COMPATIBLE_IMAGE_USED=true
				fi
			done
			"$COMPATIBLE_IMAGE_USED"
			;;
		*) printf '未预期的 docker 调用: %s\n' "$*" >&2; return 1 ;;
	esac
}
backup_adopted_database_with_postgres_client legacy-backend >/dev/null 2>&1
"$COMPATIBLE_IMAGE_USED"

# 固定提交已在本地时必须可离线复用，不再强制访问 GitHub。
DEPLOY_DIR="$fixture/offline-deploy"
repo="$DEPLOY_DIR/frappe_docker"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
touch "$repo/compose.yaml"
git -C "$repo" add compose.yaml
git -C "$repo" commit -qm initial
FRAPPE_DOCKER_REF="$(git -C "$repo" rev-parse HEAD)"
FRAPPE_DOCKER_REPO="https://github.com/transinfosh/frappe_docker.git"
download_frappe_docker >/dev/null
[[ "$FRAPPE_DOCKER_COMMIT" == "$FRAPPE_DOCKER_REF" ]]
grep -Fq 'bench --site "$SITE_NAME" set-maintenance-mode off' "$repo_root/single-node/deploy.sh"

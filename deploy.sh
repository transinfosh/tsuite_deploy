#!/usr/bin/env bash
set -Eeuo pipefail

# 可按团队环境修改这些默认值，运行时仍会逐项询问。
DEFAULT_DEPLOY_DIR="/opt/frappe-deploy"
DEFAULT_FRAPPE_DOCKER_REPO="https://github.com/transinfosh/frappe_docker.git"
DEFAULT_FRAPPE_DOCKER_REF="main"
DEFAULT_IMAGE="ghcr.io/transinfosh/project_management:0.0.2"
DEFAULT_APPS="project_management"
DEFAULT_SITE_NAME="project.localhost"
DEFAULT_DB_MODE="container"
DEFAULT_DB_PORT="5432"
DEFAULT_DB_ADMIN_USER="frappe_admin"
DEFAULT_BIND_ADDRESS="127.0.0.1"
DEFAULT_HTTP_PORT="8080"
DEFAULT_DOCKER_SUBNET="172.30.0.0/24"
DEFAULT_HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}"
DEFAULT_HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-$DEFAULT_HTTP_PROXY}}"
DEFAULT_NO_PROXY="${NO_PROXY:-${no_proxy:-localhost,127.0.0.1}}"

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=false
ASSUME_YES=false
SITE_CREATED=false
TARGET_DEPLOY_DIR=""
EXISTING_DEPLOYMENT=false
PREVIOUS_IMAGE=""
PREVIOUS_FRAPPE_DOCKER_COMMIT=""
ROLLBACK_DIR=""
DB_PASSWORD_CHANGED=false

log() {
	printf '\n\033[1;34m==>\033[0m %s\n' "$*"
}

warn() {
	printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2
}

print_failure_hint() {
	if [[ -n "$ROLLBACK_DIR" ]]; then
		warn "升级未完成，旧配置快照保存在 $ROLLBACK_DIR"
		printf '恢复旧配置后重新运行部署脚本：\n' >&2
		printf '  cp -a %q/.env %q/.env\n' "$ROLLBACK_DIR" "$DEPLOY_DIR" >&2
		printf '  cp -a %q/compose.generated.yaml %q/compose.generated.yaml\n' \
			"$ROLLBACK_DIR" "$DEPLOY_DIR" >&2
		printf '  cp -a %q/deployment.state %q/deployment.state\n' "$ROLLBACK_DIR" "$DEPLOY_DIR" >&2
		if [[ -f "$ROLLBACK_DIR/compose.proxy.yaml" ]]; then
			printf '  cp -a %q/compose.proxy.yaml %q/compose.proxy.yaml\n' \
				"$ROLLBACK_DIR" "$DEPLOY_DIR" >&2
		else
			printf '  rm -f %q/compose.proxy.yaml\n' "$DEPLOY_DIR" >&2
		fi
		printf "  git -C %q/frappe_docker checkout --detach \"\$(cat %q/frappe_docker.commit)\"\n" \
			"$DEPLOY_DIR" "$ROLLBACK_DIR" >&2
		printf '数据库备份不会自动恢复，请确认迁移影响后再决定是否恢复数据库。\n' >&2
	fi
}

die() {
	printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2
	print_failure_hint
	exit 1
}

on_error() {
	local exit_code=$?
	trap - ERR
	print_failure_hint
	exit "$exit_code"
}

run() {
	if "$DRY_RUN"; then
		printf '[dry-run]'
		printf ' %q' "$@"
		printf '\n'
		return 0
	fi
	"$@"
}

usage() {
	cat <<EOF
用法: $SCRIPT_NAME [选项]

交互式安装或升级单机 Frappe Docker 环境。

选项:
  --dry-run     只生成配置并显示系统命令，不安装软件或启动容器
  --yes         对最终部署确认使用默认答案
  --help        显示帮助

也可通过修改脚本顶部的 DEFAULT_* 值调整团队默认配置。
EOF
}

prompt() {
	local variable_name="$1"
	local message="$2"
	local default_value="${3:-}"
	local value

	if [[ -n "$default_value" ]]; then
		read -r -p "$message [$default_value]: " value
		value="${value:-$default_value}"
	else
		read -r -p "$message: " value
	fi
	printf -v "$variable_name" '%s' "$value"
}

prompt_secret() {
	local variable_name="$1"
	local message="$2"
	local default_value="${3:-}"
	local value

	if [[ -n "$default_value" ]]; then
		read -r -s -p "$message（留空使用默认值）: " value
		value="${value:-$default_value}"
	else
		read -r -s -p "$message: " value
	fi
	printf '\n'
	printf -v "$variable_name" '%s' "$value"
}

database_password_is_valid() {
	local value="$1"
	[[ -n "$value" && "$value" =~ ^[a-zA-Z0-9._~!@%^+=-]+$ ]]
}

prompt_database_password() {
	local variable_name="$1"
	local message="$2"
	local default_value="${3:-}"
	local candidate

	while true; do
		prompt_secret candidate "$message" "$default_value"
		if database_password_is_valid "$candidate"; then
			printf -v "$variable_name" '%s' "$candidate"
			return
		fi
		warn "密码不能为空；可使用字母、数字以及 . _ ~ ! @ % ^ + = -，请重新输入"
	done
}

confirm() {
	local message="$1"
	local default_answer="${2:-no}"
	local answer
	local hint="[y/N]"

	if [[ "$default_answer" == "yes" ]]; then
		hint="[Y/n]"
	fi
	read -r -p "$message $hint: " answer
	answer="${answer,,}"
	if [[ -z "$answer" ]]; then
		[[ "$default_answer" == "yes" ]]
	else
		[[ "$answer" == "y" || "$answer" == "yes" ]]
	fi
}

random_secret() {
	od -An -N18 -tx1 /dev/urandom | tr -d ' \n'
}

validate_private_subnet() {
	local subnet="$1"
	local address="${subnet%/*}"
	local prefix="${subnet##*/}"
	local first second third fourth
	[[ "$subnet" == */* && "$prefix" =~ ^[0-9]+$ ]] || return 1
	prefix=$((10#$prefix))
	((prefix >= 8 && prefix <= 30)) || return 1
	IFS=. read -r first second third fourth <<<"$address"
	local octet
	for octet in "$first" "$second" "$third" "$fourth"; do
		[[ "$octet" =~ ^[0-9]+$ ]] && ((10#$octet <= 255)) || return 1
	done
	first=$((10#$first))
	second=$((10#$second))
	third=$((10#$third))
	fourth=$((10#$fourth))

	local address_number=$(((first << 24) | (second << 16) | (third << 8) | fourth))
	local host_mask=$(((1 << (32 - prefix)) - 1))
	(( (address_number & host_mask) == 0 )) || return 1
	((first == 10)) ||
		((first == 172 && second >= 16 && second <= 31)) ||
		((first == 192 && second == 168))
}

read_config_value() {
	local file="$1"
	local key="$2"
	[[ -f "$file" ]] || return 0
	awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$file"
}

load_existing_deployment() {
	local state_file="$DEPLOY_DIR/deployment.state"
	local env_file="$DEPLOY_DIR/.env"
	[[ -f "$state_file" && -f "$env_file" ]] || return 0

	EXISTING_DEPLOYMENT=true
	PREVIOUS_IMAGE="$(read_config_value "$state_file" STATE_IMAGE)"
	PREVIOUS_FRAPPE_DOCKER_COMMIT="$(read_config_value "$state_file" STATE_FRAPPE_DOCKER_COMMIT)"
	EXISTING_SITE_NAME="$(read_config_value "$state_file" STATE_SITE_NAME)"
	EXISTING_DB_MODE="$(read_config_value "$state_file" STATE_DB_MODE)"
	EXISTING_DB_PORT="$(read_config_value "$state_file" STATE_DB_PORT)"
	EXISTING_DB_ADMIN_USER="$(read_config_value "$state_file" STATE_DB_ADMIN_USER)"
	EXISTING_BIND_ADDRESS="$(read_config_value "$state_file" STATE_BIND_ADDRESS)"
	EXISTING_HTTP_PORT="$(read_config_value "$state_file" STATE_HTTP_PORT)"
	EXISTING_DOCKER_SUBNET="$(read_config_value "$state_file" STATE_DOCKER_SUBNET)"
	EXISTING_APPS="$(read_config_value "$state_file" STATE_APPS)"
	EXISTING_DB_PASSWORD="$(read_config_value "$env_file" DB_PASSWORD)"

	log "检测到已有部署，将保留原密码和基础设施版本作为默认值"
}

require_ubuntu() {
	[[ -r /etc/os-release ]] || die "无法识别操作系统"
	# shellcheck disable=SC1091
	. /etc/os-release
	[[ "${ID:-}" == "ubuntu" ]] || die "当前仅支持 Ubuntu，检测到: ${ID:-unknown}"
	case "${VERSION_ID:-}" in
		22.04 | 24.04 | 25.10 | 26.04) ;;
		*) warn "Ubuntu ${VERSION_ID:-unknown} 未在当前脚本的验证范围内" ;;
	esac
}

require_root() {
	if [[ "$EUID" -eq 0 || "$DRY_RUN" == true ]]; then
		return
	fi
	die "请使用 sudo 运行：sudo bash $SCRIPT_NAME"
}

validate_inputs() {
	[[ "$DEPLOY_DIR" == /* ]] || die "部署目录必须是绝对路径"
	[[ "$IMAGE" =~ ^[a-zA-Z0-9._:/-]+(:[a-zA-Z0-9._-]+)?$ ]] || die "镜像名称格式无效"
	[[ "$IMAGE" != *@* ]] || die "暂不支持 digest 格式，请使用镜像标签"
	[[ "$FRAPPE_DOCKER_REPO" =~ ^(https://|ssh://|git@)[^[:space:]]+$ ]] ||
		die "frappe_docker 仓库地址格式无效"
	[[ "$FRAPPE_DOCKER_REF" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*$ ]] ||
		die "frappe_docker 分支、标签或提交格式无效"
	[[ "$SITE_NAME" =~ ^[a-zA-Z0-9.-]+$ ]] || die "站点名称只能包含字母、数字、点和连字符"
	if [[ ! "$HTTP_PORT" =~ ^[0-9]+$ ]] || ((HTTP_PORT < 1 || HTTP_PORT > 65535)); then
		die "HTTP 端口无效"
	fi
	if [[ ! "$DB_PORT" =~ ^[0-9]+$ ]] || ((DB_PORT < 1 || DB_PORT > 65535)); then
		die "PostgreSQL 端口无效"
	fi
	[[ "$DB_MODE" == "container" || "$DB_MODE" == "local" ]] || die "数据库模式无效"
	[[ "$DB_ADMIN_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "数据库管理员用户名格式无效"
	validate_private_subnet "$DOCKER_SUBNET" || die "Docker 子网格式无效，必须是规范的私有 IPv4 子网"

	local app
	for app in "${APP_LIST[@]}"; do
		[[ "$app" =~ ^[a-zA-Z0-9_]+$ ]] || die "应用名格式无效: $app"
	done

	if [[ "$DB_MODE" == "local" && "$DOCKER_SUBNET" != 172.* ]]; then
		warn "本机 PostgreSQL 模式建议使用 172.16.0.0/12 内的 Docker 子网"
	fi
}

split_image() {
	local last_segment="${IMAGE##*/}"
	if [[ "$last_segment" == *:* ]]; then
		IMAGE_REPOSITORY="${IMAGE%:*}"
		IMAGE_TAG="${IMAGE##*:}"
	else
		IMAGE_REPOSITORY="$IMAGE"
		IMAGE_TAG="latest"
	fi
}

parse_apps() {
	local normalized="${APPS_INPUT//,/ }"
	read -r -a APP_LIST <<<"$normalized"
	((${#APP_LIST[@]} > 0)) || die "至少需要指定一个应用"
}

collect_proxy_settings() {
	local proxy_default="no"
	if [[ -n "$DEFAULT_HTTP_PROXY$DEFAULT_HTTPS_PROXY" ]]; then
		proxy_default="yes"
	fi

	PROXY_ENABLED=false
	if confirm "是否为 APT、Docker 拉取和 Frappe 应用配置代理？" "$proxy_default"; then
		PROXY_ENABLED=true
		prompt HTTP_PROXY_VALUE "HTTP 代理地址" "$DEFAULT_HTTP_PROXY"
		prompt HTTPS_PROXY_VALUE "HTTPS 代理地址" "$DEFAULT_HTTPS_PROXY"
		prompt NO_PROXY_VALUE "不使用代理的地址（逗号分隔）" "$DEFAULT_NO_PROXY"
		[[ -n "$HTTP_PROXY_VALUE$HTTPS_PROXY_VALUE" ]] || die "启用代理时至少需要填写一个代理地址"

		printf '\n代理将应用到：APT、Docker daemon、Frappe 后端、队列、调度器和 WebSocket。\n'
		printf 'HTTP_PROXY=%s\nHTTPS_PROXY=%s\nNO_PROXY=%s\n' \
			"$HTTP_PROXY_VALUE" "$HTTPS_PROXY_VALUE" "$NO_PROXY_VALUE"
		confirm "确认应用上述代理设置？" "yes" || die "已取消代理配置"
	else
		HTTP_PROXY_VALUE=""
		HTTPS_PROXY_VALUE=""
		NO_PROXY_VALUE="$DEFAULT_NO_PROXY"
	fi
}

collect_deployment_settings() {
	local db_choice
	local db_choice_default="1"
	local generated_db_password
	local generated_admin_password
	local image_default
	local frappe_docker_ref_default

	prompt DEPLOY_DIR "部署目录" "$DEFAULT_DEPLOY_DIR"
	load_existing_deployment
	image_default="${PREVIOUS_IMAGE:-$DEFAULT_IMAGE}"
	frappe_docker_ref_default="${PREVIOUS_FRAPPE_DOCKER_COMMIT:-$DEFAULT_FRAPPE_DOCKER_REF}"

	prompt IMAGE "应用镜像（修改标签即可升级）" "$image_default"
	prompt APPS_INPUT "需要安装的应用，多个应用用逗号分隔" "${EXISTING_APPS:-$DEFAULT_APPS}"
	prompt SITE_NAME "Frappe 站点名称（通常使用域名）" "${EXISTING_SITE_NAME:-$DEFAULT_SITE_NAME}"
	prompt BIND_ADDRESS "HTTP 监听地址；使用 0.0.0.0 可直接对外开放" \
		"${EXISTING_BIND_ADDRESS:-$DEFAULT_BIND_ADDRESS}"
	prompt HTTP_PORT "HTTP 端口" "${EXISTING_HTTP_PORT:-$DEFAULT_HTTP_PORT}"
	prompt FRAPPE_DOCKER_REPO "frappe_docker 仓库地址" "$DEFAULT_FRAPPE_DOCKER_REPO"
	prompt FRAPPE_DOCKER_REF "frappe_docker 分支、标签或提交" "$frappe_docker_ref_default"
	prompt DOCKER_SUBNET "部署专用 Docker 子网" "${EXISTING_DOCKER_SUBNET:-$DEFAULT_DOCKER_SUBNET}"

	printf '\nPostgreSQL 部署方式：\n'
	printf '  1) PostgreSQL 容器（推荐，迁移和备份更简单）\n'
	printf '  2) 安装在 Ubuntu 本机\n'
	if [[ "${EXISTING_DB_MODE:-$DEFAULT_DB_MODE}" == "local" ]]; then
		db_choice_default="2"
	fi
	read -r -p "请选择 [$db_choice_default]: " db_choice
	case "${db_choice:-$db_choice_default}" in
		1) DB_MODE="container" ;;
		2) DB_MODE="local" ;;
		*) die "数据库选项无效" ;;
	esac

	prompt DB_PORT "PostgreSQL 端口" "${EXISTING_DB_PORT:-$DEFAULT_DB_PORT}"
	if [[ "$DB_MODE" == "local" ]]; then
		prompt DB_ADMIN_USER "用于创建站点数据库的 PostgreSQL 管理用户" \
			"${EXISTING_DB_ADMIN_USER:-$DEFAULT_DB_ADMIN_USER}"
	else
		DB_ADMIN_USER="postgres"
	fi

	generated_db_password="$(random_secret)"
	generated_admin_password="$(random_secret)"
	if database_password_is_valid "${EXISTING_DB_PASSWORD:-}"; then
		DB_PASSWORD="$EXISTING_DB_PASSWORD"
		if confirm "是否修改 PostgreSQL 管理密码？" "no"; then
			prompt_database_password DB_PASSWORD "新的 PostgreSQL 管理密码"
			DB_PASSWORD_CHANGED=true
		fi
	else
		if [[ -n "${EXISTING_DB_PASSWORD:-}" ]]; then
			warn "已有 PostgreSQL 管理密码包含不兼容字符，需要重新输入"
		fi
		prompt_database_password DB_PASSWORD "PostgreSQL 管理密码" "$generated_db_password"
	fi
	if "$EXISTING_DEPLOYMENT"; then
		ADMIN_PASSWORD="$generated_admin_password"
	else
		prompt_secret ADMIN_PASSWORD "Frappe Administrator 初始密码" "$generated_admin_password"
	fi

	parse_apps
	split_image
}

prepare_dry_run_workspace() {
	TARGET_DEPLOY_DIR="$DEPLOY_DIR"
	"$DRY_RUN" || return 0
	DEPLOY_DIR="$(mktemp -d /tmp/frappe-deploy-dry-run.XXXXXX)"
	log "dry-run 配置文件将写入 $DEPLOY_DIR"
}

show_summary() {
	printf '\n即将执行以下部署：\n'
	printf '  部署目录: %s\n' "$DEPLOY_DIR"
	printf '  镜像: %s:%s\n' "$IMAGE_REPOSITORY" "$IMAGE_TAG"
	printf '  应用: %s\n' "${APP_LIST[*]}"
	printf '  站点: %s\n' "$SITE_NAME"
	printf '  访问地址: http://%s:%s（Host: %s）\n' "$BIND_ADDRESS" "$HTTP_PORT" "$SITE_NAME"
	printf '  PostgreSQL: %s\n' "$DB_MODE"
	printf '  Docker 子网: %s\n' "$DOCKER_SUBNET"
	printf '  代理: %s\n' "$PROXY_ENABLED"
	printf '  frappe_docker: %s @ %s\n' "$FRAPPE_DOCKER_REPO" "$FRAPPE_DOCKER_REF"
	if "$EXISTING_DEPLOYMENT"; then
		printf '  当前镜像: %s\n' "${PREVIOUS_IMAGE:-未知}"
		if [[ "$PREVIOUS_IMAGE" != "$IMAGE_REPOSITORY:$IMAGE_TAG" ]]; then
			printf '  操作类型: 镜像升级\n'
		else
			printf '  操作类型: 使用同一镜像重新部署\n'
		fi
	fi

	if [[ "$BIND_ADDRESS" == "0.0.0.0" ]]; then
		warn "Docker 发布端口可能绕过 UFW；请使用云防火墙或 DOCKER-USER 链限制访问"
	fi
	if ! "$ASSUME_YES"; then
		confirm "确认开始部署？" "yes" || die "用户取消部署"
	fi
}

apply_apt_proxy() {
	local proxy_file="/etc/apt/apt.conf.d/90-frappe-deploy-proxy"
	if ! "$PROXY_ENABLED"; then
		run rm -f "$proxy_file"
		return
	fi
	export HTTP_PROXY="$HTTP_PROXY_VALUE"
	export HTTPS_PROXY="$HTTPS_PROXY_VALUE"
	export NO_PROXY="$NO_PROXY_VALUE"
	export http_proxy="$HTTP_PROXY_VALUE"
	export https_proxy="$HTTPS_PROXY_VALUE"
	export no_proxy="$NO_PROXY_VALUE"

	if "$DRY_RUN"; then
		printf '[dry-run] 写入 %s\n' "$proxy_file"
		return
	fi
	{
		[[ -z "$HTTP_PROXY_VALUE" ]] || printf 'Acquire::http::Proxy "%s";\n' "$HTTP_PROXY_VALUE"
		[[ -z "$HTTPS_PROXY_VALUE" ]] || printf 'Acquire::https::Proxy "%s";\n' "$HTTPS_PROXY_VALUE"
	} >"$proxy_file"
	chmod 600 "$proxy_file"
}

systemd_escape() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	value="${value//%/%%}"
	printf '%s' "$value"
}

apply_docker_proxy() {
	local dropin_dir="/etc/systemd/system/docker.service.d"
	local dropin="$dropin_dir/frappe-deploy-proxy.conf"
	if ! "$PROXY_ENABLED"; then
		if [[ -f "$dropin" ]]; then
			run rm -f "$dropin"
			run systemctl daemon-reload
			run systemctl restart docker
		fi
		return
	fi
	if "$DRY_RUN"; then
		printf '[dry-run] 写入 %s 并重启 Docker\n' "$dropin"
		return
	fi
	install -d -m 0755 "$dropin_dir"
	local desired_dropin
	desired_dropin="$(mktemp /tmp/frappe-deploy-docker-proxy.XXXXXX)"
	{
		printf '[Service]\n'
		[[ -z "$HTTP_PROXY_VALUE" ]] ||
			printf 'Environment="HTTP_PROXY=%s"\n' "$(systemd_escape "$HTTP_PROXY_VALUE")"
		[[ -z "$HTTPS_PROXY_VALUE" ]] ||
			printf 'Environment="HTTPS_PROXY=%s"\n' "$(systemd_escape "$HTTPS_PROXY_VALUE")"
		printf 'Environment="NO_PROXY=%s"\n' "$(systemd_escape "$NO_PROXY_VALUE")"
	} >"$desired_dropin"
	if [[ -f "$dropin" ]] && cmp -s "$desired_dropin" "$dropin"; then
		rm -f "$desired_dropin"
		log "Docker 代理配置未变化，无需重启 Docker"
		return
	fi
	install -m 0600 "$desired_dropin" "$dropin"
	rm -f "$desired_dropin"
	systemctl daemon-reload
	systemctl restart docker
}

install_base_packages() {
	log "检查基础软件"
	run apt-get update
	run apt-get install -y ca-certificates curl git jq openssl python3
}

configure_docker_repository() {
	run install -m 0755 -d /etc/apt/keyrings
	if "$DRY_RUN"; then
		printf '[dry-run] 下载 Docker 官方 GPG 密钥并配置 apt 仓库\n'
		return
	fi
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc
	# shellcheck disable=SC1091
	. /etc/os-release
	cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
}

install_docker() {
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		log "Docker 和 Compose 已安装"
		run systemctl enable --now docker
		return
	fi

	log "安装 Docker Engine 和 Compose 插件"
	configure_docker_repository
	run apt-get update
	run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	run systemctl enable --now docker
}

check_capacity() {
	local memory_mb
	local free_gb
	local capacity_path="${DEPLOY_DIR%/*}"
	[[ -n "$capacity_path" ]] || capacity_path="/"
	while [[ ! -d "$capacity_path" && "$capacity_path" != "/" ]]; do
		capacity_path="${capacity_path%/*}"
		[[ -n "$capacity_path" ]] || capacity_path="/"
	done
	memory_mb="$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)"
	free_gb="$(df -Pk "$capacity_path" 2>/dev/null | awk 'NR==2 {print int($4 / 1024 / 1024)}')"
	((memory_mb >= 2048)) || warn "内存少于 2 GB，构建索引或迁移时可能失败"
	[[ -z "$free_gb" || "$free_gb" -ge 10 ]] || warn "部署磁盘可用空间少于 10 GB"
	case "$(uname -m)" in
		x86_64 | amd64) ;;
		*) warn "当前架构为 $(uname -m)，请确认应用镜像包含对应平台" ;;
	esac
}

compose_args_from_state() {
	local root="$1"
	COMPOSE_ARGS=(--env-file "$root/.env" -p frappe -f "$root/frappe_docker/compose.yaml")
	COMPOSE_ARGS+=(-f "$root/frappe_docker/overrides/compose.redis.yaml")
	if [[ "${STATE_DB_MODE:-container}" == "container" ]]; then
		COMPOSE_ARGS+=(-f "$root/frappe_docker/overrides/compose.postgres.yaml")
	fi
	COMPOSE_ARGS+=(-f "$root/compose.generated.yaml")
	if [[ -f "$root/compose.proxy.yaml" ]]; then
		COMPOSE_ARGS+=(-f "$root/compose.proxy.yaml")
	fi
}

backup_existing_site() {
	"$DRY_RUN" && return 0
	"$EXISTING_DEPLOYMENT" || return 0
	[[ -f "$DEPLOY_DIR/frappe_docker/compose.yaml" ]] || return 0

	STATE_DB_MODE="${EXISTING_DB_MODE:-container}"
	compose_args_from_state "$DEPLOY_DIR"
	if docker compose "${COMPOSE_ARGS[@]}" ps --status running backend --quiet 2>/dev/null |
		grep -q .; then
		if ! docker compose "${COMPOSE_ARGS[@]}" exec -T backend \
			test -f "/home/frappe/frappe-bench/sites/${EXISTING_SITE_NAME:-$SITE_NAME}/site_config.json"; then
			return
		fi
		log "升级前备份站点 ${EXISTING_SITE_NAME:-$SITE_NAME}"
		run docker compose "${COMPOSE_ARGS[@]}" exec -T backend \
			bench --site "${EXISTING_SITE_NAME:-$SITE_NAME}" backup --with-files
	else
		log "后端当前未运行，使用一次性容器备份站点 ${EXISTING_SITE_NAME:-$SITE_NAME}"
		run docker compose "${COMPOSE_ARGS[@]}" run --rm backend \
			bench --site "${EXISTING_SITE_NAME:-$SITE_NAME}" backup --with-files
	fi
}

create_upgrade_snapshot() {
	"$DRY_RUN" && return 0
	"$EXISTING_DEPLOYMENT" || return 0

	ROLLBACK_DIR="$DEPLOY_DIR/rollback/$(date -u +%Y%m%dT%H%M%SZ)"
	install -d -m 0700 "$ROLLBACK_DIR"
	local file
	for file in .env compose.generated.yaml compose.proxy.yaml deployment.state; do
		if [[ -f "$DEPLOY_DIR/$file" ]]; then
			cp -a "$DEPLOY_DIR/$file" "$ROLLBACK_DIR/$file"
		fi
	done
	printf '%s\n' "$PREVIOUS_FRAPPE_DOCKER_COMMIT" >"$ROLLBACK_DIR/frappe_docker.commit"
	chmod 600 "$ROLLBACK_DIR/frappe_docker.commit"
}

download_frappe_docker() {
	local repo_dir="$DEPLOY_DIR/frappe_docker"
	log "下载 frappe_docker"
	run install -d -m 0750 "$DEPLOY_DIR"
	if "$DRY_RUN"; then
		printf '[dry-run] git clone/fetch %s，并检出 %s\n' "$FRAPPE_DOCKER_REPO" "$FRAPPE_DOCKER_REF"
		return
	fi
	if [[ -d "$repo_dir/.git" ]]; then
		if [[ -n "$(git -C "$repo_dir" status --porcelain)" ]]; then
			die "$repo_dir 存在未提交修改，请先处理后再升级"
		fi
		git -C "$repo_dir" remote set-url origin "$FRAPPE_DOCKER_REPO"
		git -C "$repo_dir" fetch --force --tags origin
	else
		git clone --filter=blob:none "$FRAPPE_DOCKER_REPO" "$repo_dir"
	fi
	git -C "$repo_dir" fetch --force origin "$FRAPPE_DOCKER_REF"
	git -C "$repo_dir" checkout --detach FETCH_HEAD
	FRAPPE_DOCKER_COMMIT="$(git -C "$repo_dir" rev-parse HEAD)"
}

sql_escape_literal() {
	local value="$1"
	printf '%s' "${value//\'/\'\'}"
}

install_local_postgres() {
	[[ "$DB_MODE" == "local" ]] || return 0
	log "安装并配置本机 PostgreSQL"
	run apt-get install -y postgresql postgresql-contrib
	if "$DRY_RUN"; then
		printf '[dry-run] 创建 PostgreSQL 管理角色 %s，监听 Docker 网关并允许子网 %s\n' \
			"$DB_ADMIN_USER" "$DOCKER_SUBNET"
		return
	fi

	local escaped_password
	local hba_file
	escaped_password="$(sql_escape_literal "$DB_PASSWORD")"
	runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$DB_ADMIN_USER') THEN
        CREATE ROLE "$DB_ADMIN_USER" LOGIN SUPERUSER PASSWORD '$escaped_password';
    ELSE
        ALTER ROLE "$DB_ADMIN_USER" WITH LOGIN SUPERUSER PASSWORD '$escaped_password';
    END IF;
END
\$\$;
ALTER SYSTEM SET listen_addresses = '*';
SQL
	hba_file="$(runuser -u postgres -- psql -Atqc 'SHOW hba_file;')"
	sed -i '/^# BEGIN frappe_deploy$/,/^# END frappe_deploy$/d' "$hba_file"
	{
		printf '\n# BEGIN frappe_deploy\n'
		printf 'host all all %s scram-sha-256\n' "$DOCKER_SUBNET"
		printf '# END frappe_deploy\n'
	} >>"$hba_file"
	systemctl restart postgresql
}

yaml_quote() {
	python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

write_env_file() {
	local env_file="$DEPLOY_DIR/.env"
	{
		printf 'CUSTOM_IMAGE=%s\n' "$IMAGE_REPOSITORY"
		printf 'CUSTOM_TAG=%s\n' "$IMAGE_TAG"
		printf 'PULL_POLICY=missing\n'
		printf 'RESTART_POLICY=unless-stopped\n'
		printf 'DB_PASSWORD=%s\n' "$DB_PASSWORD"
		printf 'HTTP_PUBLISH_PORT=%s\n' "$HTTP_PORT"
	} >"$env_file"
	chmod 600 "$env_file"
}

write_generated_compose() {
	local compose_file="$DEPLOY_DIR/compose.generated.yaml"
	local db_host="db"
	if [[ "$DB_MODE" == "local" ]]; then
		db_host="host.docker.internal"
	fi

	{
		cat <<EOF
services:
  configurator:
    environment:
      DB_HOST: $(yaml_quote "$db_host")
      DB_PORT: $(yaml_quote "$DB_PORT")
    extra_hosts:
      - "host.docker.internal:host-gateway"
  backend:
    extra_hosts:
      - "host.docker.internal:host-gateway"
  frontend:
    ports:
      - $(yaml_quote "$BIND_ADDRESS:$HTTP_PORT:8080")
    extra_hosts:
      - "host.docker.internal:host-gateway"
  websocket:
    extra_hosts:
      - "host.docker.internal:host-gateway"
  queue-short:
    extra_hosts:
      - "host.docker.internal:host-gateway"
  queue-long:
    extra_hosts:
      - "host.docker.internal:host-gateway"
  scheduler:
    extra_hosts:
      - "host.docker.internal:host-gateway"

networks:
  default:
    ipam:
      config:
        - subnet: $(yaml_quote "$DOCKER_SUBNET")
EOF
	} >"$compose_file"
	chmod 640 "$compose_file"
}

write_proxy_compose() {
	local proxy_file="$DEPLOY_DIR/compose.proxy.yaml"
	if ! "$PROXY_ENABLED"; then
		run rm -f "$proxy_file"
		return
	fi
	local combined_no_proxy="$NO_PROXY_VALUE,db,redis-cache,redis-queue,backend,frontend,websocket,$SITE_NAME"
	local service
	{
		printf 'services:\n'
		for service in configurator backend frontend websocket queue-short queue-long scheduler; do
			printf '  %s:\n' "$service"
			printf '    environment:\n'
			printf '      HTTP_PROXY: %s\n' "$(yaml_quote "$HTTP_PROXY_VALUE")"
			printf '      HTTPS_PROXY: %s\n' "$(yaml_quote "$HTTPS_PROXY_VALUE")"
			printf '      NO_PROXY: %s\n' "$(yaml_quote "$combined_no_proxy")"
			printf '      http_proxy: %s\n' "$(yaml_quote "$HTTP_PROXY_VALUE")"
			printf '      https_proxy: %s\n' "$(yaml_quote "$HTTPS_PROXY_VALUE")"
			printf '      no_proxy: %s\n' "$(yaml_quote "$combined_no_proxy")"
		done
	} >"$proxy_file"
	chmod 640 "$proxy_file"
}

write_state() {
	local state_file="$DEPLOY_DIR/deployment.state"
	local apps_csv
	apps_csv="$(IFS=,; printf '%s' "${APP_LIST[*]}")"
	{
		printf 'STATE_DB_MODE=%s\n' "$DB_MODE"
		printf 'STATE_DB_PORT=%s\n' "$DB_PORT"
		printf 'STATE_DB_ADMIN_USER=%s\n' "$DB_ADMIN_USER"
		printf 'STATE_SITE_NAME=%s\n' "$SITE_NAME"
		printf 'STATE_IMAGE=%s\n' "$IMAGE_REPOSITORY:$IMAGE_TAG"
		printf 'STATE_APPS=%s\n' "$apps_csv"
		printf 'STATE_BIND_ADDRESS=%s\n' "$BIND_ADDRESS"
		printf 'STATE_HTTP_PORT=%s\n' "$HTTP_PORT"
		printf 'STATE_DOCKER_SUBNET=%s\n' "$DOCKER_SUBNET"
		printf 'STATE_FRAPPE_DOCKER_COMMIT=%s\n' "${FRAPPE_DOCKER_COMMIT:-dry-run}"
	} >"$state_file"
	chmod 600 "$state_file"
}

prepare_compose() {
	STATE_DB_MODE="$DB_MODE"
	compose_args_from_state "$DEPLOY_DIR"
	run docker compose "${COMPOSE_ARGS[@]}" config --quiet
}

login_and_pull_image() {
	log "拉取应用镜像"
	if run docker pull "$IMAGE_REPOSITORY:$IMAGE_TAG"; then
		return
	fi
	"$DRY_RUN" && return

	if [[ "$IMAGE_REPOSITORY" != ghcr.io/* ]]; then
		die "无法拉取镜像，请先登录对应镜像仓库"
	fi

	local registry_user
	local registry_token
	prompt registry_user "GHCR 用户名" "${SUDO_USER:-${USER:-}}"
	prompt_secret registry_token "GHCR Token（至少需要 read:packages）"
	[[ -n "$registry_token" ]] || die "GHCR Token 不能为空"
	printf '%s' "$registry_token" | docker login ghcr.io -u "$registry_user" --password-stdin
	unset registry_token
	run docker pull "$IMAGE_REPOSITORY:$IMAGE_TAG"
}

wait_for_backend() {
	local attempt
	for attempt in $(seq 1 60); do
		if docker compose "${COMPOSE_ARGS[@]}" exec -T backend bench --version >/dev/null 2>&1; then
			return
		fi
		sleep 3
	done
	docker compose "${COMPOSE_ARGS[@]}" ps
	die "后端容器未在预期时间内就绪"
}

site_exists() {
	docker compose "${COMPOSE_ARGS[@]}" exec -T backend \
		test -f "/home/frappe/frappe-bench/sites/$SITE_NAME/site_config.json"
}

update_container_postgres_password() {
	[[ "$DB_MODE" == "container" && "$DB_PASSWORD_CHANGED" == true ]] || return 0
	log "更新 PostgreSQL 容器管理密码"
	docker compose "${COMPOSE_ARGS[@]}" exec -T db \
		psql -U postgres -v ON_ERROR_STOP=1 \
		-c "ALTER ROLE postgres PASSWORD '$DB_PASSWORD';"
}

install_or_upgrade_site() {
	log "启动 Frappe 服务"
	run docker compose "${COMPOSE_ARGS[@]}" up -d
	"$DRY_RUN" && return
	wait_for_backend
	update_container_postgres_password

	if ! site_exists; then
		log "创建站点 $SITE_NAME"
		docker compose "${COMPOSE_ARGS[@]}" exec -T backend \
			bench new-site "$SITE_NAME" \
			--db-type postgres \
			--db-host "$([[ "$DB_MODE" == "local" ]] && printf host.docker.internal || printf db)" \
			--db-port "$DB_PORT" \
			--db-root-username "$DB_ADMIN_USER" \
			--db-root-password "$DB_PASSWORD" \
			--admin-password "$ADMIN_PASSWORD"
		SITE_CREATED=true
	fi

	local installed_apps
	local app
	installed_apps="$(
		docker compose "${COMPOSE_ARGS[@]}" exec -T backend \
			bench --site "$SITE_NAME" list-apps
	)"
	for app in "${APP_LIST[@]}"; do
		if ! grep -Eq "^${app}([[:space:]]|$)" <<<"$installed_apps"; then
			log "安装应用 $app"
			docker compose "${COMPOSE_ARGS[@]}" exec -T backend \
				bench --site "$SITE_NAME" install-app "$app"
		fi
	done

	log "迁移站点"
	docker compose "${COMPOSE_ARGS[@]}" exec -T backend bench --site "$SITE_NAME" migrate
	docker compose "${COMPOSE_ARGS[@]}" exec -T backend bench use "$SITE_NAME"
	docker compose "${COMPOSE_ARGS[@]}" restart backend frontend websocket queue-short queue-long scheduler
}

verify_deployment() {
	"$DRY_RUN" && return
	log "验证部署"
	local attempt
	local probe_host="127.0.0.1"
	if [[ "$BIND_ADDRESS" != "0.0.0.0" && "$BIND_ADDRESS" != "::" ]]; then
		probe_host="$BIND_ADDRESS"
	fi
	for attempt in $(seq 1 30); do
		if curl --noproxy "*" -fsS -H "Host: $SITE_NAME" \
			"http://$probe_host:$HTTP_PORT/api/method/ping" >/dev/null; then
			return
		fi
		if ((attempt < 30)); then
			sleep 2
		fi
	done
	warn "容器已启动，但 HTTP 健康检查未通过"
	return 1
}

print_result() {
	printf '\n\033[1;32m部署完成\033[0m\n'
	printf '站点: %s\n' "$SITE_NAME"
	printf '镜像: %s:%s\n' "$IMAGE_REPOSITORY" "$IMAGE_TAG"
	printf '访问: http://%s:%s\n' "$BIND_ADDRESS" "$HTTP_PORT"
	printf '部署目录: %s\n' "${TARGET_DEPLOY_DIR:-$DEPLOY_DIR}"
	if "$DRY_RUN"; then
		printf 'dry-run 配置目录: %s\n' "$DEPLOY_DIR"
	else
		printf '状态命令: cd %q &&' "$DEPLOY_DIR"
		printf ' %q' docker compose "${COMPOSE_ARGS[@]}" ps
		printf '\n'
	fi
	if "$SITE_CREATED"; then
		printf 'Administrator 初始密码: %s（请立即保存并在登录后修改）\n' "$ADMIN_PASSWORD"
	fi
	if [[ "$BIND_ADDRESS" == "127.0.0.1" ]]; then
		printf '提示: 当前仅监听本机，请在前面配置 Nginx、Caddy 或云负载均衡并启用 HTTPS。\n'
	fi
}

main() {
	trap on_error ERR
	while (($#)); do
		case "$1" in
			--dry-run) DRY_RUN=true ;;
			--yes) ASSUME_YES=true ;;
			--help | -h)
				usage
				exit 0
				;;
			*) die "未知参数: $1" ;;
		esac
		shift
	done

	require_root
	require_ubuntu
	collect_proxy_settings
	collect_deployment_settings
	validate_inputs
	show_summary
	check_capacity
	prepare_dry_run_workspace
	apply_apt_proxy
	install_base_packages
	install_docker
	backup_existing_site
	create_upgrade_snapshot
	apply_docker_proxy
	login_and_pull_image
	download_frappe_docker
	write_env_file
	write_generated_compose
	write_proxy_compose
	prepare_compose
	install_local_postgres
	install_or_upgrade_site
	verify_deployment
	write_state
	print_result
}

main "$@"

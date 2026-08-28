#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s\n' \
	'错误: 堡垒机同机支持页面已停用。' \
	'请在部署控制机依次运行 control-node/prepare-support-access.sh、' \
	'堡垒机 support-session/bastion/install-console-bridge.sh，' \
	'再运行 control-node/install-support-console.sh。' >&2
exit 1

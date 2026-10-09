#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/install-support-release.sh" control/install-support-console.sh --https-proxy http://127.0.0.1:18080 "$@"

#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
UNINSTALLER_VARIANT="centos"

# shellcheck source=server/scripts/load-config.sh
source "${SCRIPT_DIR}/scripts/load-config.sh"
load_project_config "${REPO_ROOT}"

# shellcheck source=server/scripts/uninstall-common.sh
source "${SCRIPT_DIR}/scripts/uninstall-common.sh"

main_uninstall "$@"

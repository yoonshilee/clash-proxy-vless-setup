#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
SCRIPT_NAME="server/install-ubuntu.sh"
INSTALLER_VARIANT="ubuntu"

# shellcheck source=server/scripts/load-config.sh
source "${SCRIPT_DIR}/scripts/load-config.sh"
load_project_config "${REPO_ROOT}"

# shellcheck source=server/scripts/install-common.sh
source "${SCRIPT_DIR}/scripts/install-common.sh"

main_install "$@"


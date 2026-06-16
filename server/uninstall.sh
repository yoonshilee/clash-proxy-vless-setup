#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
else
    echo "Cannot detect OS: /etc/os-release is missing." >&2
    exit 1
fi

case "${ID:-}" in
    ubuntu)
        exec bash "${SCRIPT_DIR}/uninstall-ubuntu.sh" "$@"
        ;;
    centos|rhel|rocky|almalinux|fedora)
        exec bash "${SCRIPT_DIR}/uninstall-centos.sh" "$@"
        ;;
    *)
        case " ${ID_LIKE:-} " in
            *" debian "*)
                exec bash "${SCRIPT_DIR}/uninstall-ubuntu.sh" "$@"
                ;;
            *" rhel "*|*" fedora "*)
                exec bash "${SCRIPT_DIR}/uninstall-centos.sh" "$@"
                ;;
        esac
        echo "Unsupported OS: ${ID:-unknown} ${VERSION_ID:-unknown}. Use Ubuntu or a CentOS/RHEL-compatible system." >&2
        exit 1
        ;;
esac

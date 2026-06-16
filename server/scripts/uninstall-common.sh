#!/usr/bin/env bash

set -euo pipefail

UNINSTALLER_VARIANT="${UNINSTALLER_VARIANT:-}"

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || error "Please run as root (sudo)."
}

detect_os() {
    [[ -f /etc/os-release ]] || error "Cannot detect OS: /etc/os-release is missing."

    # shellcheck disable=SC1091
    . /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"

    case "${OS_ID}" in
        ubuntu)
            OS_FAMILY="ubuntu"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            OS_FAMILY="centos"
            ;;
        *)
            case " ${OS_ID_LIKE} " in
                *" rhel "*|*" fedora "*)
                    OS_FAMILY="centos"
                    ;;
                *" debian "*)
                    OS_FAMILY="ubuntu"
                    ;;
                *)
                    error "Unsupported OS: ${OS_ID} ${OS_VERSION_ID}. Use Ubuntu or a CentOS/RHEL-compatible system."
                    ;;
            esac
            ;;
    esac

    if [[ -n "${UNINSTALLER_VARIANT}" && "${UNINSTALLER_VARIANT}" != "${OS_FAMILY}" ]]; then
        error "This machine is ${OS_ID} ${OS_VERSION_ID}. Use server/uninstall-${OS_FAMILY}.sh instead."
    fi

    info "Detected OS: ${OS_ID} ${OS_VERSION_ID} (${OS_FAMILY})"
}

remove_services() {
    info "Stopping services..."
    systemctl disable --now xray 2>/dev/null || true
    systemctl disable --now caddy 2>/dev/null || true
}

remove_xray() {
    info "Removing Xray..."
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/xray@.service
    rm -rf /etc/systemd/system/xray.service.d
    rm -rf /etc/systemd/system/xray@.service.d
    rm -rf /usr/local/etc/xray
    rm -f /usr/local/bin/xray
    rm -rf /usr/local/share/xray
    systemctl daemon-reload
}

remove_caddy() {
    info "Removing Caddy configs..."
    rm -rf /etc/caddy /var/lib/clash-sub
    rm -f /etc/systemd/system/caddy.service.d/env.conf
    rmdir /etc/systemd/system/caddy.service.d 2>/dev/null || true
    systemctl daemon-reload
}

remove_firewall_rules() {
    local firewall_script=""

    case "${OS_FAMILY}" in
        centos)
            firewall_script="${REPO_ROOT}/server/scripts/close-firewall-centos.sh"
            ;;
        ubuntu)
            firewall_script="${REPO_ROOT}/server/scripts/close-firewall-ubuntu.sh"
            ;;
    esac

    [[ -n "${firewall_script}" && -f "${firewall_script}" ]] || error "Missing firewall cleanup script for ${OS_FAMILY}: ${firewall_script}"

    info "Removing firewall rules with ${firewall_script##*/}..."
    XRAY_PORT="${XRAY_PORT}" \
    SUBSCRIPTION_PORT="${SUBSCRIPTION_PORT}" \
    bash "${firewall_script}"
}

remove_selinux_labels() {
    if [[ "${OS_FAMILY}" != "centos" ]]; then
        return
    fi

    info "Removing SELinux port labels (${SUBSCRIPTION_PORT})..."
    semanage port -d -t http_port_t -p tcp "${SUBSCRIPTION_PORT}" 2>/dev/null || true
}

cleanup_local_user() {
    userdel clashsub 2>/dev/null || true
}

print_uninstall_summary() {
    echo "Legacy Shadowsocks config and binaries were left in place."
    echo "Done."
}

main_uninstall() {
    require_root
    detect_os
    remove_services
    remove_xray
    remove_caddy
    remove_firewall_rules
    remove_selinux_labels
    cleanup_local_user
    print_uninstall_summary
}

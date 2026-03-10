#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# uninstall.sh
#
# Stops the autokill-unresponsive-process daemon, removes the binary and
# launchd plist, and optionally cleans up configuration and log files.
#
# Usage:
#   ./uninstall.sh              # Uninstall, keep config & logs
#   ./uninstall.sh --purge      # Uninstall and remove config & logs too
# ─────────────────────────────────────────────────────────────────────────────

readonly PRODUCT_NAME="autokill-unresponsive-process"
readonly LAUNCHD_LABEL="com.autokill.unresponsive"

# Install locations (must match install.sh)
readonly INSTALL_DIR="${HOME}/.local/bin"
readonly INSTALL_PATH="${INSTALL_DIR}/${PRODUCT_NAME}"
readonly LAUNCHD_PLIST_DIR="${HOME}/Library/LaunchAgents"
readonly LAUNCHD_PLIST_PATH="${LAUNCHD_PLIST_DIR}/${LAUNCHD_LABEL}.plist"
readonly CONFIG_DIR="${HOME}/.config/autokill-unresponsive"
readonly LOG_DIR="${HOME}/.local/log/autokill-unresponsive"

# Colors (disabled if stdout is not a terminal)
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[0;33m'
    readonly BLUE='\033[0;34m'
    readonly BOLD='\033[1m'
    readonly RESET='\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

info()    { echo -e "${BLUE}ℹ${RESET}  $*"; }
success() { echo -e "${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET}  $*"; }
error()   { echo -e "${RED}✖${RESET}  $*" >&2; }
step()    { echo -e "\n${BOLD}→ $*${RESET}"; }

# ─────────────────────────────────────────────────────────────────────────────
# Parse flags
# ─────────────────────────────────────────────────────────────────────────────
PURGE=false
for arg in "$@"; do
    case "${arg}" in
        --purge)
            PURGE=true
            ;;
        --help|-h)
            echo "Usage: $(basename "$0") [--purge]"
            echo ""
            echo "  --purge    Also remove configuration files and logs"
            echo "  --help     Show this help message"
            exit 0
            ;;
        *)
            error "Unknown option: ${arg}"
            error "Run with --help for usage information."
            exit 1
            ;;
    esac
done

echo -e "${BOLD}Uninstalling ${PRODUCT_NAME}${RESET}"

# ─────────────────────────────────────────────────────────────────────────────
# Stop the daemon
# ─────────────────────────────────────────────────────────────────────────────
step "Stopping daemon"

DAEMON_STOPPED=false

# Try the modern launchctl bootout first
if launchctl list "${LAUNCHD_LABEL}" &>/dev/null; then
    if launchctl bootout "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null; then
        DAEMON_STOPPED=true
        success "Daemon stopped via launchctl bootout"
    elif launchctl unload "${LAUNCHD_PLIST_PATH}" 2>/dev/null; then
        DAEMON_STOPPED=true
        success "Daemon stopped via launchctl unload"
    else
        warn "Could not stop daemon via launchctl"
    fi
else
    info "Daemon is not currently loaded in launchd"
fi

# Kill any lingering process as a safety net
if pgrep -x "${PRODUCT_NAME}" &>/dev/null; then
    if pkill -x "${PRODUCT_NAME}" 2>/dev/null; then
        success "Killed lingering ${PRODUCT_NAME} process"
    else
        warn "Found a running ${PRODUCT_NAME} process but could not kill it"
    fi

    # Wait briefly for the process to exit
    for _ in 1 2 3 4 5; do
        if ! pgrep -x "${PRODUCT_NAME}" &>/dev/null; then
            break
        fi
        sleep 0.5
    done

    # Escalate to SIGKILL if still alive
    if pgrep -x "${PRODUCT_NAME}" &>/dev/null; then
        warn "Process still alive after SIGTERM — sending SIGKILL"
        pkill -9 -x "${PRODUCT_NAME}" 2>/dev/null || true
        sleep 1
    fi
elif [[ "${DAEMON_STOPPED}" == false ]]; then
    info "No running ${PRODUCT_NAME} process found"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Remove launchd plist
# ─────────────────────────────────────────────────────────────────────────────
step "Removing launchd agent plist"

if [[ -f "${LAUNCHD_PLIST_PATH}" ]]; then
    rm -f "${LAUNCHD_PLIST_PATH}"
    success "Removed ${LAUNCHD_PLIST_PATH}"
else
    info "Plist not found at ${LAUNCHD_PLIST_PATH} — nothing to remove"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Remove binary
# ─────────────────────────────────────────────────────────────────────────────
step "Removing binary"

if [[ -f "${INSTALL_PATH}" ]]; then
    rm -f "${INSTALL_PATH}"
    success "Removed ${INSTALL_PATH}"
else
    info "Binary not found at ${INSTALL_PATH} — nothing to remove"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Optionally remove config and logs (--purge)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${PURGE}" == true ]]; then
    step "Purging configuration"

    if [[ -d "${CONFIG_DIR}" ]]; then
        rm -rf "${CONFIG_DIR}"
        success "Removed ${CONFIG_DIR}"
    else
        info "Config directory not found at ${CONFIG_DIR} — nothing to remove"
    fi

    step "Purging logs"

    if [[ -d "${LOG_DIR}" ]]; then
        rm -rf "${LOG_DIR}"
        success "Removed ${LOG_DIR}"
    else
        info "Log directory not found at ${LOG_DIR} — nothing to remove"
    fi
else
    step "Keeping configuration and logs"

    info "Config directory preserved at ${CONFIG_DIR}"
    info "Log directory preserved at ${LOG_DIR}"
    info "Run with ${BOLD}--purge${RESET} to remove these as well"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Uninstallation complete!${RESET}"
echo ""

if [[ "${PURGE}" == false ]]; then
    echo "The following were preserved (use --purge to remove):"
    [[ -d "${CONFIG_DIR}" ]] && echo "  Config: ${CONFIG_DIR}"
    [[ -d "${LOG_DIR}" ]]    && echo "  Logs:   ${LOG_DIR}"
    echo ""
fi

echo "To reinstall, run:"
echo "  ./install.sh"
echo ""

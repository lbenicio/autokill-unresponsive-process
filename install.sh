#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# install.sh
#
# Builds the autokill-unresponsive-process daemon from source, installs the
# binary, and registers a launchd user agent so it starts automatically on
# login.
#
# Usage:
#   ./install.sh              # Build release & install
#   ./install.sh --debug      # Build debug & install
#   ./install.sh --uninstall  # Remove everything (delegates to uninstall.sh)
# ─────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PRODUCT_NAME="autokill-unresponsive-process"
readonly LAUNCHD_LABEL="com.autokill.unresponsive"
readonly PLIST_TEMPLATE="${SCRIPT_DIR}/${LAUNCHD_LABEL}.plist"

# Install locations
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
# Handle --uninstall flag
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
    if [[ -x "${SCRIPT_DIR}/uninstall.sh" ]]; then
        exec "${SCRIPT_DIR}/uninstall.sh"
    else
        error "uninstall.sh not found in ${SCRIPT_DIR}"
        exit 1
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Determine build configuration
# ─────────────────────────────────────────────────────────────────────────────
BUILD_CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
    BUILD_CONFIG="debug"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────────────────────────────────────
step "Pre-flight checks"

if ! command -v swift &>/dev/null; then
    error "Swift toolchain not found. Install Xcode or Xcode Command Line Tools:"
    error "  xcode-select --install"
    exit 1
fi

SWIFT_VERSION="$(swift --version 2>&1 | head -1)"
info "Swift: ${SWIFT_VERSION}"

if [[ ! -f "${SCRIPT_DIR}/Package.swift" ]]; then
    error "Package.swift not found in ${SCRIPT_DIR}. Are you in the right directory?"
    exit 1
fi

success "All checks passed"

# ─────────────────────────────────────────────────────────────────────────────
# Stop existing daemon (if running)
# ─────────────────────────────────────────────────────────────────────────────
step "Stopping existing daemon (if running)"

if launchctl list "${LAUNCHD_LABEL}" &>/dev/null; then
    launchctl bootout "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null || \
        launchctl unload "${LAUNCHD_PLIST_PATH}" 2>/dev/null || true
    success "Stopped existing daemon"
else
    info "No existing daemon running"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────────────
step "Building (${BUILD_CONFIG} configuration)"

cd "${SCRIPT_DIR}"

swift build -c "${BUILD_CONFIG}" 2>&1 | while IFS= read -r line; do
    echo "  ${line}"
done

BUILD_EXIT=${PIPESTATUS[0]}
if [[ ${BUILD_EXIT} -ne 0 ]]; then
    error "Build failed with exit code ${BUILD_EXIT}"
    exit 1
fi

# Locate the built binary
BUILD_DIR="${SCRIPT_DIR}/.build/${BUILD_CONFIG}"
BUILT_BINARY="${BUILD_DIR}/${PRODUCT_NAME}"

if [[ ! -x "${BUILT_BINARY}" ]]; then
    error "Built binary not found at ${BUILT_BINARY}"
    exit 1
fi

success "Build succeeded: ${BUILT_BINARY}"

# ─────────────────────────────────────────────────────────────────────────────
# Create directories
# ─────────────────────────────────────────────────────────────────────────────
step "Creating directories"

mkdir -p "${INSTALL_DIR}"
mkdir -p "${LAUNCHD_PLIST_DIR}"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${LOG_DIR}"

success "Directories ready"

# ─────────────────────────────────────────────────────────────────────────────
# Install binary
# ─────────────────────────────────────────────────────────────────────────────
step "Installing binary"

cp -f "${BUILT_BINARY}" "${INSTALL_PATH}"
chmod 755 "${INSTALL_PATH}"

success "Installed to ${INSTALL_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# Install launchd plist
# ─────────────────────────────────────────────────────────────────────────────
step "Installing launchd agent plist"

if [[ ! -f "${PLIST_TEMPLATE}" ]]; then
    error "Plist template not found at ${PLIST_TEMPLATE}"
    exit 1
fi

# Replace placeholder paths in the template with actual install paths
sed \
    -e "s|__INSTALL_PATH__|${INSTALL_DIR}|g" \
    -e "s|__LOG_DIR__|${LOG_DIR}|g" \
    "${PLIST_TEMPLATE}" > "${LAUNCHD_PLIST_PATH}"

success "Plist installed to ${LAUNCHD_PLIST_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# Create default config (if it doesn't exist)
# ─────────────────────────────────────────────────────────────────────────────
step "Checking configuration"

CONFIG_FILE="${CONFIG_DIR}/config.json"
if [[ ! -f "${CONFIG_FILE}" ]]; then
    cat > "${CONFIG_FILE}" <<'EOF'
{
    "checkIntervalSeconds": 10,
    "graceBeforeTermSeconds": 30,
    "graceBeforeKillSeconds": 10,
    "dryRun": false,
    "notifyOnKill": true,
    "maxKillsPerCycle": 5,
    "excludedBundleIdentifiers": [],
    "excludedProcessNames": []
}
EOF
    success "Created default config at ${CONFIG_FILE}"
    info "Edit this file to customize behavior. Entries in the exclusion lists"
    info "are merged with built-in exclusions (Finder, Dock, loginwindow, etc.)"
else
    info "Config already exists at ${CONFIG_FILE} — not overwriting"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Ensure ~/.local/bin is in PATH
# ─────────────────────────────────────────────────────────────────────────────
step "Checking PATH"

if echo "${PATH}" | tr ':' '\n' | grep -qx "${INSTALL_DIR}"; then
    success "${INSTALL_DIR} is already in PATH"
else
    warn "${INSTALL_DIR} is not in your PATH"
    info "Add the following to your shell profile (~/.zshrc, ~/.bashrc, etc.):"
    echo ""
    echo "    export PATH=\"${INSTALL_DIR}:\$PATH\""
    echo ""
fi

# ─────────────────────────────────────────────────────────────────────────────
# Load launchd agent
# ─────────────────────────────────────────────────────────────────────────────
step "Loading launchd agent"

if launchctl bootstrap "gui/$(id -u)" "${LAUNCHD_PLIST_PATH}" 2>/dev/null; then
    success "Agent loaded via launchctl bootstrap"
else
    # Fallback for older macOS versions
    if launchctl load -w "${LAUNCHD_PLIST_PATH}" 2>/dev/null; then
        success "Agent loaded via launchctl load"
    else
        warn "Could not auto-load the agent. You may need to log out and back in,"
        warn "or manually run:  launchctl load -w ${LAUNCHD_PLIST_PATH}"
    fi
fi

# Verify it's running
sleep 1
if launchctl list "${LAUNCHD_LABEL}" &>/dev/null; then
    success "Daemon is running"
else
    warn "Daemon does not appear to be running yet. Check logs at:"
    warn "  ${LOG_DIR}/"
    warn "  or run: log stream --predicate 'subsystem == \"com.autokill.unresponsive\"'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Installation complete!${RESET}"
echo ""
echo "  Binary:    ${INSTALL_PATH}"
echo "  Config:    ${CONFIG_FILE}"
echo "  Plist:     ${LAUNCHD_PLIST_PATH}"
echo "  Logs:      ${LOG_DIR}/"
echo ""
echo "Useful commands:"
echo "  ${BOLD}View live logs:${RESET}"
echo "    log stream --predicate 'subsystem == \"com.autokill.unresponsive\"' --level debug"
echo ""
echo "  ${BOLD}View log file:${RESET}"
echo "    tail -f ${LOG_DIR}/autokill.log"
echo ""
echo "  ${BOLD}Test with a single scan:${RESET}"
echo "    ${PRODUCT_NAME} --once --verbose"
echo ""
echo "  ${BOLD}Dry-run mode (no kills):${RESET}"
echo "    ${PRODUCT_NAME} --dry-run --verbose"
echo ""
echo "  ${BOLD}Reload config (while running):${RESET}"
echo "    kill -HUP \$(pgrep -x ${PRODUCT_NAME})"
echo ""
echo "  ${BOLD}Stop daemon:${RESET}"
echo "    launchctl bootout gui/\$(id -u)/${LAUNCHD_LABEL}"
echo ""
echo "  ${BOLD}Uninstall:${RESET}"
echo "    ./uninstall.sh"
echo ""

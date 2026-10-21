#!/bin/bash
#
# NVLink Status Collector - Installation Script (Cron-based)
#
# Usage:
#   sudo bash install.sh [OPTIONS]
#
# Options:
#   --output PATH    .prom file output path (default: /usr/local/node_exporter/extra_metrics_custom/nvlink_status.prom)
#   --uninstall      Remove the installed cron jobs and files
#

set -euo pipefail

# Default configuration
BINARY_NAME="nvlink_collector"
INSTALL_DIR="/usr/local/bin"
PROM_OUTPUT_DIR="/usr/local/node_exporter/extra_metrics_custom"
PROM_OUTPUT_PATH="${PROM_OUTPUT_DIR}/nvlink_status.prom"
CRON_MARKER="NVLINK_COLLECTOR"
UNINSTALL=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --output)
            PROM_OUTPUT_PATH="$2"
            PROM_OUTPUT_DIR=$(dirname "$PROM_OUTPUT_PATH")
            shift 2
            ;;
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        --help|-h)
            head -n 12 "$0" | tail -n +2 | sed 's/^# //'
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

uninstall() {
    info "Uninstalling NVLink Status Collector..."

    # Remove cron jobs
    CRON_BEFORE=$(crontab -l 2>/dev/null || true)
    CRON_AFTER=$(echo "${CRON_BEFORE}" | grep -v "${CRON_MARKER}" || true)

    if [[ "${CRON_BEFORE}" != "${CRON_AFTER}" ]]; then
        echo "${CRON_AFTER}" | crontab -
        info "Cron jobs removed"
    else
        info "No cron jobs found to remove"
    fi

    # Remove binary
    if [[ -f "${INSTALL_DIR}/${BINARY_NAME}" ]]; then
        rm -f "${INSTALL_DIR}/${BINARY_NAME}"
        info "Binary removed from ${INSTALL_DIR}"
    fi

    # Remove .prom file
    if [[ -f "${PROM_OUTPUT_PATH}" ]]; then
        rm -f "${PROM_OUTPUT_PATH}"
        info ".prom file removed"
    fi

    # Remove lock file (used for single-instance serialization; safe to
    # delete after cron and binary are gone, since no collector can be
    # running anymore once cron stops launching new instances)
    if [[ -f "${PROM_OUTPUT_PATH}.lock" ]]; then
        rm -f "${PROM_OUTPUT_PATH}.lock"
        info "Lock file removed"
    fi

    info "Uninstallation complete"
    exit 0
}

install() {
    # Check root privileges
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi

    # Check binary exists
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    BINARY_SRC="${SCRIPT_DIR}/${BINARY_NAME}"

    if [[ ! -f "${BINARY_SRC}" ]]; then
        error "Binary not found: ${BINARY_SRC}"
    fi

    # Verify binary is executable
    info "Verifying binary..."
    if "${BINARY_SRC}" --help &>/dev/null; then
        info "Binary verification passed"
    else
        warn "Binary --help check failed, but continuing installation"
    fi

    # Create output directory
    if [[ ! -d "${PROM_OUTPUT_DIR}" ]]; then
        mkdir -p "${PROM_OUTPUT_DIR}"
        chmod 755 "${PROM_OUTPUT_DIR}"
        info "Created output directory: ${PROM_OUTPUT_DIR}"
    fi

    # Install binary
    cp "${BINARY_SRC}" "${INSTALL_DIR}/${BINARY_NAME}"
    chmod 755 "${INSTALL_DIR}/${BINARY_NAME}"
    info "Installed binary to ${INSTALL_DIR}/${BINARY_NAME}"

    # Remove old cron jobs if they exist
    CRON_EXISTING=$(crontab -l 2>/dev/null || true)
    CRON_CLEAN=$(echo "${CRON_EXISTING}" | grep -v "${CRON_MARKER}" || true)

    # Watchdog: 'timeout -k 5 25' sends SIGTERM after 25s, then SIGKILL after
    # 5 more seconds. The SIGKILL escalation is essential: a collector hung in
    # a blocking NVML ioctl cannot be terminated by SIGTERM alone (Python
    # signal handlers do not run while blocked inside a ctypes call).
    # Normal collection takes ~5s, so 25s gives a 5x margin.
    WATCHDOG="timeout -k 5 25"

    # Add cron jobs (dual task for 30-second interval)
    # Task 1: Run at every minute
    # Task 2: Run at 30 seconds past every minute (sleep 30 then run)
    CRON_NEW="${CRON_CLEAN}
# ${CRON_MARKER} - NVLink Status Collector (do not modify this line)
* * * * * ${WATCHDOG} ${INSTALL_DIR}/${BINARY_NAME} --once --output ${PROM_OUTPUT_PATH} # ${CRON_MARKER}
* * * * * sleep 30; ${WATCHDOG} ${INSTALL_DIR}/${BINARY_NAME} --once --output ${PROM_OUTPUT_PATH} # ${CRON_MARKER}"

    echo "${CRON_NEW}" | crontab -
    info "Cron jobs installed (30-second interval, watchdog timeout 25s + SIGKILL after 5s)"

    # Test run
    info "Running test collection..."
    if "${INSTALL_DIR}/${BINARY_NAME}" --once --output "${PROM_OUTPUT_PATH}" 2>&1; then
        info "Test collection successful"
    else
        warn "Test collection failed - this is expected on non-GPU machines"
    fi

    echo ""
    info "========================================="
    info "NVLink Status Collector installed!"
    info "========================================="
    info ""
    info "Configuration:"
    info "  Binary:     ${INSTALL_DIR}/${BINARY_NAME}"
    info "  Output:     ${PROM_OUTPUT_PATH}"
    info "  Interval:   30s (via dual cron jobs)"
    info "  Watchdog:   timeout 25s, SIGKILL after 5s (hung runs cannot pile up)"
    info "  Lock:       ${PROM_OUTPUT_PATH}.lock (single-instance, kernel-released)"
    info ""
    info "Cron jobs:"
    info "  $(crontab -l | grep ${CRON_MARKER} | head -1)"
    info "  $(crontab -l | grep ${CRON_MARKER} | tail -1)"
    info ""
    info "Useful commands:"
    info "  View cron:       crontab -l"
    info "  Test run:        ${INSTALL_DIR}/${BINARY_NAME} --once --output /tmp/nvlink_test.prom"
    info "  View output:     cat ${PROM_OUTPUT_PATH}"
    info "  Uninstall:       sudo bash $0 --uninstall"
    info ""
}

if [[ "${UNINSTALL}" == true ]]; then
    uninstall
else
    install
fi

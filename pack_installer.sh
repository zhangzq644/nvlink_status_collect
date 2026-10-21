#!/bin/bash
#
# NVLink Status Collector - Package Installer Script
#
# Usage:
#   bash pack_installer.sh
#
# This script creates a self-extracting .sh installer that contains:
#   - nvlink_collector binary
#   - install.sh (cron-based deployment)
#
# The generated installer can be distributed to target machines.
# Run it with: sudo bash nvlink_status_collect_install.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build_output"
BINARY_PATH="${BUILD_DIR}/dist/nvlink_collector"
INSTALL_SCRIPT="${SCRIPT_DIR}/install.sh"
OUTPUT_NAME="nvlink_status_collect_install.sh"
OUTPUT_PATH="${SCRIPT_DIR}/${OUTPUT_NAME}"
STAGING_DIR=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

cleanup() {
    if [[ -n "${STAGING_DIR}" ]] && [[ -d "${STAGING_DIR}" ]]; then
        rm -rf "${STAGING_DIR}"
    fi
}
trap cleanup EXIT

# Check binary exists
if [[ ! -f "${BINARY_PATH}" ]]; then
    error "Binary not found at ${BINARY_PATH}. Run build_binary.sh first."
fi

# Check install script exists
if [[ ! -f "${INSTALL_SCRIPT}" ]]; then
    error "Install script not found at ${INSTALL_SCRIPT}"
fi

# Create staging directory
STAGING_DIR=$(mktemp -d)
info "Staging directory: ${STAGING_DIR}"

# Copy files to staging
cp "${BINARY_PATH}" "${STAGING_DIR}/nvlink_collector"
chmod +x "${STAGING_DIR}/nvlink_collector"

cp "${INSTALL_SCRIPT}" "${STAGING_DIR}/install.sh"
chmod +x "${STAGING_DIR}/install.sh"

# Create tar.gz archive
ARCHIVE_PATH="${STAGING_DIR}/payload.tar.gz"
info "Creating archive..."
cd "${STAGING_DIR}"
tar czf "${ARCHIVE_PATH}" nvlink_collector install.sh
cd "${SCRIPT_DIR}"

ARCHIVE_SIZE=$(du -h "${ARCHIVE_PATH}" | cut -f1)
info "Archive size: ${ARCHIVE_SIZE}"

# Generate self-extracting installer
info "Generating self-extracting installer..."
cat > "${OUTPUT_PATH}" << 'HEADER_EOF'
#!/bin/bash
#
# NVLink Status Collector - Self-Extracting Installer
#
# Usage:
#   sudo bash nvlink_status_collect_install.sh [OPTIONS]
#
# Options (passed to install.sh):
#   --output PATH    .prom file output path
#   --uninstall      Remove the installed service and files
#
# This script will:
#   1. Extract files to a temporary directory
#   2. Run install.sh automatically
#   3. Clean up temporary files
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check root
if [[ $EUID -ne 0 ]]; then
    error "This installer must be run as root (use sudo)"
fi

# Find the archive marker line
ARCHIVE_LINE=$(awk '/^__ARCHIVE_BELOW__$/ {print NR + 1; exit 0; }' "$0")

# Create temporary directory
EXTRACT_DIR=$(mktemp -d /tmp/nvlink_install.XXXXXX)
info "Extracting to ${EXTRACT_DIR}..."

# Extract the archive
tail -n +${ARCHIVE_LINE} "$0" | tar xz -C "${EXTRACT_DIR}"

info "Extraction complete"

# Run install script with all arguments
info "Running installer..."
cd "${EXTRACT_DIR}"
bash install.sh "$@"
INSTALL_EXIT=$?

# Cleanup
cd /
rm -rf "${EXTRACT_DIR}"

if [[ ${INSTALL_EXIT} -eq 0 ]]; then
    info "Installation complete!"
else
    error "Installation failed with exit code ${INSTALL_EXIT}"
fi

exit ${INSTALL_EXIT}

__ARCHIVE_BELOW__
HEADER_EOF

# Append the archive
cat "${ARCHIVE_PATH}" >> "${OUTPUT_PATH}"
chmod +x "${OUTPUT_PATH}"

# Show result
OUTPUT_SIZE=$(du -h "${OUTPUT_PATH}" | cut -f1)
info "========================================="
info "Self-extracting installer created!"
info "========================================="
info "  File:       ${OUTPUT_PATH}"
info "  Size:       ${OUTPUT_SIZE}"
info ""
info "Usage on target machine:"
info "  sudo bash ${OUTPUT_NAME}"
info "  sudo bash ${OUTPUT_NAME} --output /custom/path/nvlink.prom"
info "  sudo bash ${OUTPUT_NAME} --uninstall"

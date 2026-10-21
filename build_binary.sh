#!/bin/bash
#
# NVLink Status Collector - Binary Build Script
#
# Usage:
#   bash build_binary.sh
#
# This script uses PyInstaller inside a Docker Ubuntu 22.04 container
# to build a single binary executable for x86_64 Linux.
# Building on an older glibc ensures forward compatibility.
#
# Requirements:
#   - Docker
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build_output"
BINARY_NAME="nvlink_collector"
DOCKER_IMAGE="ubuntu:22.04"
DOCKER_PLATFORM="linux/amd64"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check Docker
if ! command -v docker &>/dev/null; then
    error "Docker is not installed. Please install Docker first."
fi
info "Docker: $(docker --version)"

# Clean previous build
if [[ -d "${BUILD_DIR}" ]]; then
    info "Cleaning previous build..."
    rm -rf "${BUILD_DIR}"
fi
mkdir -p "${BUILD_DIR}"

# Build inside Docker container (Ubuntu 22.04 for glibc 2.35 compatibility)
# Force linux/amd64 platform for x86_64 target
info "Building binary in Docker container (${DOCKER_IMAGE}, platform: ${DOCKER_PLATFORM})..."

docker run --rm \
    --platform "${DOCKER_PLATFORM}" \
    -v "${SCRIPT_DIR}:/src:ro" \
    -v "${BUILD_DIR}:/output" \
    -e BINARY_NAME="${BINARY_NAME}" \
    "${DOCKER_IMAGE}" \
    bash -c '
set -euo pipefail

# Install Python3 and pip
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-dev > /dev/null 2>&1

echo "[INFO] Python3: $(python3 --version)"
echo "[INFO] glibc: $(ldd --version 2>&1 | head -1)"
echo "[INFO] Architecture: $(uname -m)"

# Install PyInstaller and nvidia-ml-py
pip3 install pyinstaller nvidia-ml-py 2>/dev/null

# Build with PyInstaller
cd /src

pyinstaller --onefile \
    --name "${BINARY_NAME}" \
    --hidden-import pynvml \
    --collect-all pynvml \
    --distpath /output/dist \
    --workpath /output/build \
    --specpath /output \
    nvlink_collector.py

# Verify
if [[ -f "/output/dist/${BINARY_NAME}" ]]; then
    chmod +x "/output/dist/${BINARY_NAME}"
    echo "[INFO] Build successful!"
    echo "[INFO] Size: $(du -h /output/dist/${BINARY_NAME} | cut -f1)"
    echo "[INFO] Architecture: $(file /output/dist/${BINARY_NAME})"
else
    echo "[ERROR] Binary not found!"
    exit 1
fi
'

# Verify output
BINARY_PATH="${BUILD_DIR}/dist/${BINARY_NAME}"
if [[ ! -f "${BINARY_PATH}" ]]; then
    error "Binary not found at ${BINARY_PATH}"
fi

# Verify architecture (read ELF header directly - no 'file' command needed)
# ELF e_machine field at offset 18: 0x3E = x86-64, 0xB7 = aarch64
BINARY_MACHINE=$(od -An -tx1 -j18 -N2 "${BINARY_PATH}" | tr -d ' \n')
if [[ "${BINARY_MACHINE}" == "3e00" ]]; then
    info "Architecture check passed: x86-64"
else
    error "Binary architecture field is '${BINARY_MACHINE}', expected '3e00' (x86-64). The build may have failed to use the correct platform."
fi

# Show result
BINARY_SIZE=$(du -h "${BINARY_PATH}" | cut -f1)
info "========================================="
info "Build successful!"
info "========================================="
info "  Binary:       ${BINARY_PATH}"
info "  Size:         ${BINARY_SIZE}"
info "  Architecture: x86_64"
info "  Built on:     Ubuntu 22.04 (glibc 2.35)"
info "  Compatible:   Ubuntu 22.04+ / glibc 2.35+"
info ""
info "Next step: run pack_installer.sh to create the self-extracting installer"

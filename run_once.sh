#!/bin/bash
#
# NVLink Status Collector - One-shot Run Script
#
# Runs the collector once for testing purposes.
# Installs dependencies from local packages/ directory if needed,
# then executes a single collection and outputs the result.
#
# Usage:
#   bash run_once.sh [OUTPUT_PATH]
#

set -euo pipefail

# Default output path
OUTPUT_PATH="${1:-/tmp/nvlink_status.prom}"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGES_DIR="${SCRIPT_DIR}/packages"
COLLECTOR="${SCRIPT_DIR}/nvlink_collector.py"
# Directory for extracting wheel if pip is not available
LOCAL_LIB_DIR="${SCRIPT_DIR}/lib"

echo "=== NVLink Status Collector - One-shot Run ==="
echo ""

# Step 1: Check Python3
if ! command -v python3 &>/dev/null; then
    echo "[ERROR] python3 is not installed. Please install Python 3 first."
    exit 1
fi
echo "[INFO] Python3: $(python3 --version)"

# Step 2: Ensure nvidia-ml-py (pynvml module) is available
if python3 -c "import pynvml" 2>/dev/null; then
    echo "[INFO] nvidia-ml-py (pynvml module) is already installed"
    PYTHON_EXEC="python3"
else
    echo "[INFO] nvidia-ml-py not found, installing..."

    # Find local wheel file
    local_wheel=$(ls "${PACKAGES_DIR}"/nvidia_ml_py-*.whl 2>/dev/null | head -1)

    install_success=false

    # Method 1: Try pip install (if pip is available)
    if python3 -m pip --version &>/dev/null; then
        echo "[INFO] pip is available, trying pip install..."
        if [[ -n "${local_wheel}" ]]; then
            echo "[INFO] Installing from local wheel: ${local_wheel}"
            if python3 -m pip install "${local_wheel}" --user --break-system-packages 2>/dev/null; then
                install_success=true
                echo "[INFO] Installed nvidia-ml-py from local wheel via pip"
            fi
        else
            echo "[WARN] No local wheel found, trying online install..."
            if python3 -m pip install nvidia-ml-py --user --break-system-packages 2>/dev/null; then
                install_success=true
                echo "[INFO] Installed nvidia-ml-py from PyPI via pip"
            fi
        fi
    fi

    # Method 2: Direct wheel extraction (no pip needed)
    if [[ "${install_success}" == "false" ]] && [[ -n "${local_wheel}" ]]; then
        echo "[INFO] pip not available or failed, extracting wheel directly..."
        mkdir -p "${LOCAL_LIB_DIR}"
        # wheel is a zip file, extract the pynvml package
        python3 -c "
import zipfile, os, shutil
whl = '${local_wheel}'
dest = '${LOCAL_LIB_DIR}'
# Clean previous extraction
for d in os.listdir(dest):
    p = os.path.join(dest, d)
    if os.path.isdir(p) and (d.startswith('pynvml') or d.endswith('.dist-info')):
        shutil.rmtree(p)
with zipfile.ZipFile(whl, 'r') as z:
    for name in z.namelist():
        # Extract pynvml package and its dependencies
        if name.startswith('pynvml/') or name.startswith('pynvml.py'):
            z.extract(name, dest)
" || {
            # Fallback: use unzip if python zipfile fails
            echo "[INFO] Python zipfile failed, trying unzip..."
            mkdir -p "${LOCAL_LIB_DIR}"
            cd "${LOCAL_LIB_DIR}" && unzip -o -q "${local_wheel}" 'pynvml/*' 'pynvml.py' 2>/dev/null || true
            cd "${SCRIPT_DIR}"
        }

        # Verify extraction
        if [[ -d "${LOCAL_LIB_DIR}/pynvml" ]] || [[ -f "${LOCAL_LIB_DIR}/pynvml.py" ]]; then
            install_success=true
            echo "[INFO] Extracted nvidia-ml-py to ${LOCAL_LIB_DIR}/"
        else
            echo "[ERROR] Failed to extract wheel file"
        fi
    fi

    if [[ "${install_success}" == "false" ]]; then
        echo "[ERROR] Could not install nvidia-ml-py. No pip and no local wheel available."
        echo "[HINT] Install pip first: apt install python3-pip  OR  yum install python3-pip"
        exit 1
    fi
fi

# Step 3: Verify pynvml works (with LOCAL_LIB_DIR in path if needed)
if [[ -d "${LOCAL_LIB_DIR}/pynvml" ]] || [[ -f "${LOCAL_LIB_DIR}/pynvml.py" ]]; then
    PYTHONPATH="${LOCAL_LIB_DIR}:${PYTHONPATH:-}"
    export PYTHONPATH
fi

if ! python3 -c "import pynvml; pynvml.nvmlInit(); pynvml.nvmlShutdown()" 2>/dev/null; then
    echo "[ERROR] NVML initialization failed. Is NVIDIA driver installed?"
    exit 1
fi
echo "[INFO] NVML initialization OK"

# Step 4: Run collector once
echo ""
echo "[INFO] Running collector (one-shot mode)..."
echo "[INFO] Output: ${OUTPUT_PATH}"
echo ""

python3 "${COLLECTOR}" --once --output "${OUTPUT_PATH}" --log-level INFO

# Step 5: Show result
if [[ -f "${OUTPUT_PATH}" ]]; then
    echo ""
    echo "=== Collection Result ==="
    cat "${OUTPUT_PATH}"
    echo ""
    echo "[INFO] Result written to: ${OUTPUT_PATH}"
else
    echo "[ERROR] Output file not created"
    exit 1
fi

#!/bin/bash
set -euo pipefail

echo "========================================"
echo " ChuD InfiniteTalk One-Click Public V1 "
echo "========================================"

REPO_RAW="https://raw.githubusercontent.com/Chudeer89/chud-infinitetalk-runpod/main"
BASE="/opt/chud"
COMFY="$BASE/ComfyUI"
VENV="$BASE/venv"

mkdir -p "$BASE"

echo
echo "=== GPU ==="
nvidia-smi --query-gpu=name,memory.total \
  --format=csv,noheader 2>/dev/null || true

VRAM="$(nvidia-smi --query-gpu=memory.total \
  --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)"

if [ "${VRAM:-0}" -lt 30000 ]; then
    echo
    echo "[WARNING] This Public V1 is tested for GPUs with about 32 GB VRAM or more."
    echo "[WARNING] Detected: ${VRAM:-unknown} MB"
fi

# ---------------------------------------
# 1. Install Stable Runtime
# ---------------------------------------
if [ ! -f "$BASE/.runtime-ready" ]; then

    echo
    echo "=== Installing Stable Runtime ==="

    curl -fL \
      "$REPO_RAW/install.sh" \
      -o /tmp/chud-install.sh

    bash /tmp/chud-install.sh

    touch "$BASE/.runtime-ready"

else
    echo "[OK] Runtime already installed."
fi

# ---------------------------------------
# 2. Download Models
# ---------------------------------------
if [ ! -f "$BASE/.models-ready" ]; then

    echo
    echo "=== Downloading InfiniteTalk Models ==="
    echo "First boot can take several minutes."

    curl -fL \
      "$REPO_RAW/download-models.sh" \
      -o /tmp/chud-download-models.sh

    bash /tmp/chud-download-models.sh

    touch "$BASE/.models-ready"

else
    echo "[OK] Models already downloaded."
fi

# ---------------------------------------
# 3. Refresh Stable Workflow
# ---------------------------------------
mkdir -p "$COMFY/user/default/workflows"

curl -fL \
  "$REPO_RAW/infinitetalk%201.json" \
  -o "$COMFY/user/default/workflows/infinitetalk.json"

python3 -m json.tool \
  "$COMFY/user/default/workflows/infinitetalk.json" \
  >/dev/null

echo "[OK] Stable workflow ready."

# ---------------------------------------
# 4. Start ComfyUI
# ---------------------------------------
echo
echo "========================================"
echo " ChuD InfiniteTalk READY"
echo " Open RunPod HTTP Port 8188"
echo "========================================"
echo

cd "$COMFY"

if [ -n "${RUNPOD_POD_ID:-}" ]; then
    CORS="https://${RUNPOD_POD_ID}-8188.proxy.runpod.net"
else
    CORS="*"
fi

exec "$VENV/bin/python" main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  --enable-cors-header "$CORS"

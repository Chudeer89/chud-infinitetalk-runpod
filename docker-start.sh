#!/bin/bash
set -euo pipefail

BASE="/opt/chud"
COMFY="$BASE/ComfyUI"
VENV="$BASE/venv"
DOWNLOADER="$BASE/download-models.sh"

export HF_XET_HIGH_PERFORMANCE=1
export HF_HUB_DISABLE_XET=0
export HF_HOME="$BASE/hf-cache"
export PYTHONUNBUFFERED=1

echo "================================================"
echo " ChuD InfiniteTalk One-Click Public V1.4       "
echo " Docker Runtime + hf_xet Models                "
echo "================================================"
echo

if [ -x /start.sh ]; then
    echo "[RUNPOD] Starting base RunPod services in background..."
    /start.sh >/tmp/runpod-base.log 2>&1 &
fi

if [ ! -f "$BASE/.runtime-v1.4-image" ]; then
    echo "[ERROR] V1.4 baked-runtime marker not found."
    exit 1
fi

if [ ! -x "$VENV/bin/python" ] || [ ! -d "$COMFY" ]; then
    echo "[ERROR] Baked runtime is missing."
    exit 1
fi

mkdir -p "$HF_HOME"

echo "=== Runtime ==="
echo "Runtime: PREBUILT IN DOCKER IMAGE"
echo "HF_XET_HIGH_PERFORMANCE=$HF_XET_HIGH_PERFORMANCE"
echo "HF_HOME=$HF_HOME"
echo

echo "=== GPU ==="
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || true

VRAM="$(
    nvidia-smi \
        --query-gpu=memory.total \
        --format=csv,noheader,nounits \
        2>/dev/null \
    | head -1 || echo 0
)"

if [ "${VRAM:-0}" -lt 30000 ]; then
    echo "[WARNING] ChuD InfiniteTalk is tested for GPUs with about 32 GB VRAM or more."
    echo "[WARNING] Detected VRAM: ${VRAM:-unknown} MB"
fi

echo
echo "=== Disk ==="
df -h / || true
df -h /opt || true

echo
echo "=== Model Phase ==="
echo "[INFO] Runtime install is skipped."
echo "[INFO] Existing valid models are reused."
echo "[INFO] Missing models download automatically with hf_xet High Performance."
echo

bash "$DOWNLOADER"

echo
echo "=== Workflow Check ==="
WORKFLOW="$COMFY/user/default/workflows/infinitetalk.json"
"$VENV/bin/python" -m json.tool "$WORKFLOW" >/dev/null
echo "[OK] Stable InfiniteTalk workflow ready."

echo
echo "=== Final Runtime Check ==="
"$VENV/bin/python" - <<'PY'
import torch
import transformers
import diffusers
import huggingface_hub
import hf_xet
import safetensors

print("torch:", torch.__version__)
print("transformers:", transformers.__version__)
print("diffusers:", diffusers.__version__)
print("huggingface_hub:", huggingface_hub.__version__)
print("hf_xet: READY")
print("safetensors:", safetensors.__version__)
print("ChuD V1.4 runtime check: PASS")
PY

echo
echo "================================================"
echo " ChuD InfiniteTalk V1.4 READY                  "
echo " Runtime: Docker image                         "
echo " Models: hf_xet / local NVMe                   "
echo " Open RunPod HTTP Port 8188                    "
echo "================================================"
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

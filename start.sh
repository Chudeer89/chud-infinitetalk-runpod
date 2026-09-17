#!/bin/bash
set -euo pipefail

echo "================================================"
echo " ChuD InfiniteTalk One-Click Public V1.1       "
echo " hf_xet High Performance + Model Verification  "
echo "================================================"

RELEASE_REF="bdeedb520d69d97cc53c96a46278d7ba9f769058"
REPO_RAW="https://raw.githubusercontent.com/Chudeer89/chud-infinitetalk-runpod/${RELEASE_REF}"

BASE="/opt/chud"
COMFY="$BASE/ComfyUI"
VENV="$BASE/venv"

RUNTIME_MARKER="$BASE/.runtime-v1.1-ready"
MODELS_MARKER="$BASE/.models-v1.1-ready"

mkdir -p "$BASE"

# =========================================================
# Hugging Face Xet High Performance
# =========================================================
export HF_XET_HIGH_PERFORMANCE=1
export HF_HUB_DISABLE_XET=0
export HF_HOME="$BASE/hf-cache"
export PYTHONUNBUFFERED=1

mkdir -p "$HF_HOME"

echo
echo "=== ChuD Environment ==="
echo "HF_XET_HIGH_PERFORMANCE=$HF_XET_HIGH_PERFORMANCE"
echo "HF_HOME=$HF_HOME"

# =========================================================
# GPU information
# =========================================================
echo
echo "=== GPU ==="

nvidia-smi \
    --query-gpu=name,memory.total \
    --format=csv,noheader \
    2>/dev/null || true

VRAM="$(
    nvidia-smi \
        --query-gpu=memory.total \
        --format=csv,noheader,nounits \
        2>/dev/null \
    | head -1 || echo 0
)"

if [ "${VRAM:-0}" -lt 30000 ]; then
    echo
    echo "[WARNING] ChuD InfiniteTalk V1.1 is tested for GPUs"
    echo "[WARNING] with approximately 32 GB VRAM or more."
    echo "[WARNING] Detected VRAM: ${VRAM:-unknown} MB"
fi

# =========================================================
# Disk information
# =========================================================
echo
echo "=== Disk ==="
df -h /opt || true

# =========================================================
# 1. Install / verify stable runtime
# =========================================================
NEED_RUNTIME=0

if [ ! -f "$RUNTIME_MARKER" ]; then
    NEED_RUNTIME=1
fi

if [ ! -x "$VENV/bin/python" ]; then
    NEED_RUNTIME=1
fi

if [ ! -d "$COMFY/.git" ]; then
    NEED_RUNTIME=1
fi

if [ "$NEED_RUNTIME" -eq 0 ]; then
    if ! "$VENV/bin/python" - <<'PY' >/dev/null 2>&1
import huggingface_hub
import hf_xet
import safetensors
PY
    then
        NEED_RUNTIME=1
    fi
fi

if [ "$NEED_RUNTIME" -eq 1 ]; then

    echo
    echo "=== Installing Stable Runtime V1.1 ==="

    curl \
        -fL \
        --retry 10 \
        --retry-delay 3 \
        "$REPO_RAW/install.sh" \
        -o /tmp/chud-install.sh

    bash /tmp/chud-install.sh

    touch "$RUNTIME_MARKER"

    echo "[OK] Runtime V1.1 installed."

else

    echo
    echo "[OK] Runtime V1.1 already installed."

fi

# =========================================================
# 2. Download AND verify models
#
# IMPORTANT:
# We intentionally run this on every startup.
#
# Existing valid models are skipped quickly.
# Corrupt/incomplete models are detected and replaced.
# =========================================================
echo
echo "=== Checking InfiniteTalk Models ==="

curl \
    -fL \
    --retry 10 \
    --retry-delay 3 \
    "$REPO_RAW/download-models.sh" \
    -o /tmp/chud-download-models.sh

bash /tmp/chud-download-models.sh

touch "$MODELS_MARKER"

echo
echo "[OK] All model files verified."

# =========================================================
# 3. Refresh Stable Workflow
# =========================================================
echo
echo "=== Installing Stable Workflow ==="

mkdir -p "$COMFY/user/default/workflows"

WORKFLOW_TMP="$COMFY/user/default/workflows/infinitetalk.json.tmp"
WORKFLOW_FINAL="$COMFY/user/default/workflows/infinitetalk.json"

rm -f "$WORKFLOW_TMP"

curl \
    -fL \
    --retry 10 \
    --retry-delay 3 \
    "$REPO_RAW/infinitetalk%201.json" \
    -o "$WORKFLOW_TMP"

"$VENV/bin/python" -m json.tool \
    "$WORKFLOW_TMP" \
    >/dev/null

mv -f \
    "$WORKFLOW_TMP" \
    "$WORKFLOW_FINAL"

echo "[OK] Stable workflow verified."

# =========================================================
# 4. Final runtime check
# =========================================================
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
print("ChuD runtime check: PASS")
PY

# =========================================================
# 5. Start ComfyUI
# =========================================================
echo
echo "================================================"
echo " ChuD InfiniteTalk READY                      "
echo " Models verified                              "
echo " hf_xet High Performance enabled              "
echo " Open RunPod HTTP Port 8188                   "
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

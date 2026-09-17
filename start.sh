#!/bin/bash
set -euo pipefail

echo "================================================"
echo " ChuD InfiniteTalk One-Click Public V1.2       "
echo " Auto Persistent + hf_xet High Performance    "
echo "================================================"

# V1.2 keeps the already-tested V1.1 runtime/model payload locked.
RELEASE_REF="bdeedb520d69d97cc53c96a46278d7ba9f769058"
REPO_RAW="https://raw.githubusercontent.com/Chudeer89/chud-infinitetalk-runpod/${RELEASE_REF}"

# =========================================================
# Storage mode
# If RunPod has persistent storage mounted at /workspace,
# keep the complete ChuD installation there.
# Otherwise fall back to the original ephemeral /opt/chud.
# =========================================================
PERSISTENT_STORAGE=0
STORAGE_MODE="Ephemeral"
PERSIST_BASE="/workspace/chud"

if [ -d /workspace ] && [ -w /workspace ]; then
    ROOT_SOURCE="$(findmnt -T / -n -o SOURCE 2>/dev/null || true)"
    WORKSPACE_SOURCE="$(findmnt -T /workspace -n -o SOURCE 2>/dev/null || true)"
    ROOT_DEVICE="$(df -P / 2>/dev/null | awk 'NR==2 {print $1}' || true)"
    WORKSPACE_DEVICE="$(df -P /workspace 2>/dev/null | awk 'NR==2 {print $1}' || true)"

    if [ -n "$WORKSPACE_SOURCE" ] && [ "$WORKSPACE_SOURCE" != "$ROOT_SOURCE" ]; then
        PERSISTENT_STORAGE=1
    elif [ -n "$WORKSPACE_DEVICE" ] && [ "$WORKSPACE_DEVICE" != "$ROOT_DEVICE" ]; then
        PERSISTENT_STORAGE=1
    elif mountpoint -q /workspace 2>/dev/null; then
        PERSISTENT_STORAGE=1
    fi
fi

if [ "$PERSISTENT_STORAGE" -eq 1 ]; then
    STORAGE_MODE="Persistent /workspace"
    mkdir -p "$PERSIST_BASE"

    if [ -e /opt/chud ] && [ ! -L /opt/chud ]; then
        if find /opt/chud -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
            echo "[STORAGE] Existing /opt/chud detected. Migrating to $PERSIST_BASE ..."
            cp -a /opt/chud/. "$PERSIST_BASE"/
        fi
        rm -rf /opt/chud
    elif [ -L /opt/chud ]; then
        rm -f /opt/chud
    fi

    ln -s "$PERSIST_BASE" /opt/chud
else
    if [ -L /opt/chud ] && [ ! -e /opt/chud ]; then
        rm -f /opt/chud
    fi
    mkdir -p /opt/chud
fi

BASE="/opt/chud"
COMFY="$BASE/ComfyUI"
VENV="$BASE/venv"

RUNTIME_MARKER="$BASE/.runtime-v1.1-ready"
MODELS_MARKER="$BASE/.models-v1.1-ready"

mkdir -p "$BASE"

export HF_XET_HIGH_PERFORMANCE=1
export HF_HUB_DISABLE_XET=0
export HF_HOME="$BASE/hf-cache"
export PYTHONUNBUFFERED=1

mkdir -p "$HF_HOME"

echo
echo "=== ChuD Environment ==="
echo "Storage mode: $STORAGE_MODE"
echo "Data root: $BASE"

if [ "$PERSISTENT_STORAGE" -eq 1 ]; then
    echo "Persistent root: $PERSIST_BASE"
    echo "[OK] Stop/restart can reuse runtime, models and HF cache."
    echo "[OK] A new Pod can reuse them when the same Network Volume is attached."
else
    echo "[INFO] No persistent /workspace mount detected."
    echo "[INFO] Running in V1.1-compatible ephemeral mode."
fi

echo "HF_XET_HIGH_PERFORMANCE=$HF_XET_HIGH_PERFORMANCE"
echo "HF_HOME=$HF_HOME"

echo
echo "=== GPU ==="

nvidia-smi     --query-gpu=name,memory.total     --format=csv,noheader     2>/dev/null || true

VRAM="$(
    nvidia-smi         --query-gpu=memory.total         --format=csv,noheader,nounits         2>/dev/null     | head -1 || echo 0
)"

if [ "${VRAM:-0}" -lt 30000 ]; then
    echo
    echo "[WARNING] ChuD InfiniteTalk V1.2 is tested for GPUs"
    echo "[WARNING] with approximately 32 GB VRAM or more."
    echo "[WARNING] Detected VRAM: ${VRAM:-unknown} MB"
fi

echo
echo "=== Disk ==="
df -h /opt || true
if [ -d /workspace ]; then
    df -h /workspace || true
fi

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
    echo "=== Installing Stable Runtime V1.1 Payload ==="

    curl         -fL         --retry 10         --retry-delay 3         "$REPO_RAW/install.sh"         -o /tmp/chud-install.sh

    bash /tmp/chud-install.sh

    touch "$RUNTIME_MARKER"
    echo "[OK] Runtime V1.1 payload installed."
else
    echo
    echo "[OK] Persistent runtime already installed. Skipping reinstall."
fi

echo
echo "=== Checking InfiniteTalk Models ==="

curl     -fL     --retry 10     --retry-delay 3     "$REPO_RAW/download-models.sh"     -o /tmp/chud-download-models.sh

bash /tmp/chud-download-models.sh

touch "$MODELS_MARKER"

echo
echo "[OK] All model files verified."

echo
echo "=== Installing Stable Workflow ==="

mkdir -p "$COMFY/user/default/workflows"

WORKFLOW_TMP="$COMFY/user/default/workflows/infinitetalk.json.tmp"
WORKFLOW_FINAL="$COMFY/user/default/workflows/infinitetalk.json"

rm -f "$WORKFLOW_TMP"

curl     -fL     --retry 10     --retry-delay 3     "$REPO_RAW/infinitetalk%201.json"     -o "$WORKFLOW_TMP"

"$VENV/bin/python" -m json.tool     "$WORKFLOW_TMP"     >/dev/null

mv -f     "$WORKFLOW_TMP"     "$WORKFLOW_FINAL"

echo "[OK] Stable workflow verified."

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

echo
echo "================================================"
echo " ChuD InfiniteTalk V1.2 READY                 "
echo " Storage: $STORAGE_MODE"
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

exec "$VENV/bin/python" main.py     --listen 0.0.0.0     --port 8188     --enable-cors-header "$CORS"

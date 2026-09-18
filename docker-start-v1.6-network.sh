#!/bin/bash
set -euo pipefail

BASE="/opt/chud"
COMFY="$BASE/ComfyUI"
VENV="$BASE/venv"
DOWNLOADER="$BASE/download-models.sh"

NETWORK_MOUNT="/workspace"
NETWORK_ROOT="$NETWORK_MOUNT/chud/infinitetalk"
NETWORK_MODELS="$NETWORK_ROOT/models"
NETWORK_HF_CACHE="$NETWORK_ROOT/hf-cache"
NETWORK_STAGE="$NETWORK_ROOT/hf-stage"

export HF_XET_HIGH_PERFORMANCE=1
export HF_HUB_DISABLE_XET=0
export PYTHONUNBUFFERED=1

echo "================================================"
echo " ChuD InfiniteTalk One-Click Public V1.6       "
echo " Docker Runtime + Persistent Network Volume    "
echo " Models load directly from /workspace          "
echo "================================================"
echo

# Start RunPod base services (Jupyter/SSH) without replacing our app.
if [ -x /start.sh ]; then
    echo "[RUNPOD] Starting base RunPod services in background..."
    /start.sh >/tmp/runpod-base.log 2>&1 &
    sleep 2
fi

# V1.6 runs on the already-tested V1.4 Docker runtime.
if [ ! -f "$BASE/.runtime-v1.4-image" ]; then
    echo "[FATAL] V1.4 baked-runtime marker not found."
    echo "[FATAL] Use ghcr.io/chudeer89/chud-infinitetalk:1.4 or newer."
    exit 10
fi

if [ ! -x "$VENV/bin/python" ] || [ ! -d "$COMFY" ]; then
    echo "[FATAL] Baked runtime is missing."
    exit 11
fi

echo "=== Runtime ==="
echo "Runtime: PREBUILT IN DOCKER IMAGE"
echo "hf_xet High Performance: ENABLED"
echo

echo "=== GPU ==="
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || true
echo

# =========================================================
# CUDA preflight: prove actual GPU compute works BEFORE
# touching/downloading the 27+ GiB model set.
# =========================================================
echo "=== CUDA Preflight ==="

CUDA_OK=0

for attempt in $(seq 1 12); do
    echo "[CUDA] Health check attempt ${attempt}/12..."

    if "$VENV/bin/python" - <<'PY'
import ctypes
import os
import sys

print("CUDA_VISIBLE_DEVICES:", os.environ.get("CUDA_VISIBLE_DEVICES", "<unset>"))
print("NVIDIA_VISIBLE_DEVICES:", os.environ.get("NVIDIA_VISIBLE_DEVICES", "<unset>"))

try:
    libcuda = ctypes.CDLL("libcuda.so.1")
    rc = int(libcuda.cuInit(0))
    print("cuInit:", rc)
    if rc != 0:
        raise RuntimeError(f"cuInit returned {rc}")
except Exception as e:
    print("CUDA_DRIVER_INIT_FAIL:", repr(e))
    sys.exit(20)

import torch

print("torch:", torch.__version__)
print("torch.version.cuda:", torch.version.cuda)

if not torch.cuda.is_available():
    print("torch.cuda.is_available(): False")
    sys.exit(21)

count = torch.cuda.device_count()
print("torch.cuda.device_count():", count)

if count < 1:
    sys.exit(22)

device = torch.device("cuda:0")
print("CUDA device 0:", torch.cuda.get_device_name(device))

x = torch.tensor([1.0], device=device)
y = (x + 1.0).item()
torch.cuda.synchronize(device)

if y != 2.0:
    raise RuntimeError(f"Unexpected CUDA compute result: {y}")

print("CUDA_COMPUTE_TEST: PASS")
PY
    then
        CUDA_OK=1
        echo "[CUDA] HEALTHY"
        break
    fi

    if [ "$attempt" -lt 12 ]; then
        echo "[CUDA] Not ready/healthy yet. Retrying in 5 seconds..."
        sleep 5
    fi
done

if [ "$CUDA_OK" -ne 1 ]; then
    echo
    echo "================================================"
    echo " FATAL: RUNPOD GPU HOST CUDA IS UNHEALTHY      "
    echo "================================================"
    echo "[FATAL] Model validation/download was NOT started."
    echo "[ACTION] Terminate this Pod and deploy on another GPU host."
    nvidia-smi || true
    exit 42
fi

echo

# =========================================================
# Require a real persistent Network Volume mounted at
# /workspace. Do not silently fall back to local disk.
# =========================================================
echo "=== Network Volume Check ==="

if [ ! -d "$NETWORK_MOUNT" ] || [ ! -w "$NETWORK_MOUNT" ]; then
    echo "[FATAL] /workspace is missing or not writable."
    echo "[ACTION] Attach your RunPod Network Volume and deploy again."
    exit 50
fi

ROOT_SOURCE="$(findmnt -T / -n -o SOURCE 2>/dev/null || true)"
WORKSPACE_SOURCE="$(findmnt -T "$NETWORK_MOUNT" -n -o SOURCE 2>/dev/null || true)"
ROOT_DEVICE="$(df -P / 2>/dev/null | awk 'NR==2 {print $1}' || true)"
WORKSPACE_DEVICE="$(df -P "$NETWORK_MOUNT" 2>/dev/null | awk 'NR==2 {print $1}' || true)"

if [ -z "$WORKSPACE_SOURCE" ] && [ -z "$WORKSPACE_DEVICE" ]; then
    echo "[FATAL] Cannot identify storage backing /workspace."
    echo "[ACTION] Attach a RunPod Network Volume and deploy again."
    exit 51
fi

if [ "$WORKSPACE_SOURCE" = "$ROOT_SOURCE" ] && [ "$WORKSPACE_DEVICE" = "$ROOT_DEVICE" ]; then
    echo "[FATAL] /workspace appears to be on the container disk, not a persistent volume."
    echo "[ACTION] Attach your RunPod Network Volume and deploy again."
    exit 52
fi

mkdir -p \
    "$NETWORK_MODELS" \
    "$NETWORK_HF_CACHE" \
    "$NETWORK_STAGE"

echo "[OK] Persistent /workspace detected."
echo "Network root : $NETWORK_ROOT"
echo "Models       : $NETWORK_MODELS"
echo "HF cache     : $NETWORK_HF_CACHE"
echo "HF stage     : $NETWORK_STAGE"
df -h "$NETWORK_MOUNT" || true
echo

# Need enough room for the model set plus download/cache working space.
FREE_KB="$(df -Pk "$NETWORK_MOUNT" | awk 'NR==2 {print $4}')"
MIN_FREE_KB=$((35 * 1024 * 1024))

if [ "${FREE_KB:-0}" -lt "$MIN_FREE_KB" ]; then
    echo "[WARNING] Network Volume has less than ~35 GiB free."
    echo "[WARNING] First-time model download may run out of space."
fi

# =========================================================
# Make the proven V1.1 downloader write DIRECTLY to the
# Network Volume. No Global->Local and no Network->Local
# copy on future Pods.
# =========================================================
echo "=== Persistent Model Wiring ==="

LOCAL_MODELS="$COMFY/models"

if [ -L "$LOCAL_MODELS" ]; then
    CURRENT_TARGET="$(readlink -f "$LOCAL_MODELS" 2>/dev/null || true)"
    if [ "$CURRENT_TARGET" != "$NETWORK_MODELS" ]; then
        rm -f "$LOCAL_MODELS"
    fi
elif [ -d "$LOCAL_MODELS" ]; then
    # Preserve any tiny directory structure shipped in the image.
    # The baked image contains no 27 GiB model payload.
    cp -a "$LOCAL_MODELS/." "$NETWORK_MODELS/" 2>/dev/null || true
    rm -rf "$LOCAL_MODELS"
elif [ -e "$LOCAL_MODELS" ]; then
    echo "[FATAL] Unexpected non-directory path at $LOCAL_MODELS"
    exit 53
fi

if [ ! -L "$LOCAL_MODELS" ]; then
    ln -s "$NETWORK_MODELS" "$LOCAL_MODELS"
fi

# Persist hf_xet cache + partial staging too, so an interrupted first
# download can resume on a later Pod.
for pair in \
    "$BASE/hf-cache:$NETWORK_HF_CACHE" \
    "$BASE/hf-stage:$NETWORK_STAGE"
do
    LOCAL_PATH="${pair%%:*}"
    NETWORK_PATH="${pair#*:}"

    if [ -L "$LOCAL_PATH" ]; then
        CURRENT_TARGET="$(readlink -f "$LOCAL_PATH" 2>/dev/null || true)"
        if [ "$CURRENT_TARGET" != "$NETWORK_PATH" ]; then
            rm -f "$LOCAL_PATH"
        fi
    elif [ -d "$LOCAL_PATH" ]; then
        cp -a "$LOCAL_PATH/." "$NETWORK_PATH/" 2>/dev/null || true
        rm -rf "$LOCAL_PATH"
    elif [ -e "$LOCAL_PATH" ]; then
        rm -f "$LOCAL_PATH"
    fi

    if [ ! -L "$LOCAL_PATH" ]; then
        ln -s "$NETWORK_PATH" "$LOCAL_PATH"
    fi
done

export HF_HOME="$BASE/hf-cache"

echo "[OK] ComfyUI models -> $NETWORK_MODELS"
echo "[OK] hf_xet cache     -> $NETWORK_HF_CACHE"
echo "[OK] hf_xet stage     -> $NETWORK_STAGE"
echo

echo "=== Model Verification / First-Time Download ==="
echo "[INFO] First deploy: missing models download once to Network Volume."
echo "[INFO] Future Pods: valid models are reused directly from Network Volume."
echo "[INFO] No 27 GiB copy to container disk is performed."
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
import ctypes
import os
from pathlib import Path

import torch
import transformers
import diffusers
import huggingface_hub
import hf_xet
import safetensors

rc = int(ctypes.CDLL("libcuda.so.1").cuInit(0))
if rc != 0:
    raise SystemExit(f"FINAL CUDA CHECK FAILED: cuInit={rc}")

if not torch.cuda.is_available():
    raise SystemExit("FINAL CUDA CHECK FAILED: torch.cuda.is_available() is False")

device = torch.device("cuda:0")
probe = (torch.tensor([2.0], device=device) * 3.0).item()
torch.cuda.synchronize(device)

if probe != 6.0:
    raise SystemExit(f"FINAL CUDA COMPUTE CHECK FAILED: result={probe}")

models = Path("/opt/chud/ComfyUI/models")
resolved = models.resolve()

if str(resolved) != "/workspace/chud/infinitetalk/models":
    raise SystemExit(f"MODEL STORAGE CHECK FAILED: {models} -> {resolved}")

print("torch:", torch.__version__)
print("torch CUDA:", torch.version.cuda)
print("GPU:", torch.cuda.get_device_name(device))
print("transformers:", transformers.__version__)
print("diffusers:", diffusers.__version__)
print("huggingface_hub:", huggingface_hub.__version__)
print("hf_xet: READY")
print("safetensors:", safetensors.__version__)
print("Persistent models:", resolved)
print("CUDA compute: PASS")
print("ChuD V1.6 runtime check: PASS")
PY

echo
echo "================================================"
echo " ChuD InfiniteTalk V1.6 READY                  "
echo " Runtime: Docker image                         "
echo " Models: Persistent Network Volume             "
echo " Model path: /workspace/chud/infinitetalk      "
echo " Future Pod: NO 27 GiB redownload/copy         "
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

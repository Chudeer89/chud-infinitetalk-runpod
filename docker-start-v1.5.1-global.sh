#!/bin/bash
set -euo pipefail

BASE="/opt/chud"
COMFY="$BASE/ComfyUI"
VENV="$BASE/venv"
LOCAL_MODELS="$COMFY/models"
DOWNLOADER="$BASE/download-models.sh"

GLOBAL_MOUNT="/workspace-global"
GLOBAL_ROOT="$GLOBAL_MOUNT/chud/infinitetalk"
GLOBAL_MODELS="$GLOBAL_ROOT/models"

export HF_XET_HIGH_PERFORMANCE=1
export HF_HUB_DISABLE_XET=0
export HF_HOME="$BASE/hf-cache"
export PYTHONUNBUFFERED=1

echo "================================================"
echo " ChuD InfiniteTalk One-Click Public V1.5.1     "
echo " Global Cache + CUDA Preflight + hf_xet        "
echo "================================================"
echo

# Keep RunPod base services available when the image provides /start.sh.
if [ -x /start.sh ]; then
    echo "[RUNPOD] Starting base RunPod services in background..."
    /start.sh >/tmp/runpod-base.log 2>&1 &
    sleep 2
fi

# V1.5 is designed to run on the proven V1.4 Docker runtime.
if [ ! -f "$BASE/.runtime-v1.4-image" ]; then
    echo "[ERROR] V1.4 baked-runtime marker not found."
    echo "[ERROR] Use ghcr.io/chudeer89/chud-infinitetalk:1.4 or newer."
    exit 1
fi

if [ ! -x "$VENV/bin/python" ] || [ ! -d "$COMFY" ]; then
    echo "[ERROR] Baked runtime is missing."
    exit 1
fi

mkdir -p "$HF_HOME" "$LOCAL_MODELS"

echo "=== Runtime ==="
echo "Runtime: PREBUILT IN DOCKER IMAGE"
echo "HF_XET_HIGH_PERFORMANCE=$HF_XET_HIGH_PERFORMANCE"
echo "HF_HOME=$HF_HOME"
echo

echo "=== GPU ==="
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || true
echo

# =========================================================
# CUDA preflight BEFORE model copy/download
# =========================================================
# nvidia-smi alone is not enough: a broken RunPod host can expose the
# management device while CUDA compute (cuInit / PyTorch) is unusable.
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
name = torch.cuda.get_device_name(device)
print("CUDA device 0:", name)

# Prove actual compute/memory access, not just enumeration.
x = torch.tensor([1.0], device=device)
y = (x + 1.0).item()

if y != 2.0:
    raise RuntimeError(f"Unexpected CUDA compute result: {y}")

torch.cuda.synchronize(device)
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
    echo "[FATAL] nvidia-smi may still show the GPU, but CUDA compute failed."
    echo "[FATAL] Model copy/download was NOT started, so no time is wasted."
    echo "[ACTION] Terminate this Pod and deploy on another GPU host."
    echo
    echo "=== CUDA diagnostics ==="
    nvidia-smi || true
    echo
    echo "/dev/nvidia*:"
    ls -l /dev/nvidia* 2>/dev/null || true
    echo
    echo "/dev/nvidia-caps/*:"
    ls -l /dev/nvidia-caps/* 2>/dev/null || echo "NO NVIDIA CAPS NODES"
    exit 42
fi

echo
echo "=== Disk ==="
df -h / || true
[ -d "$GLOBAL_MOUNT" ] && df -h "$GLOBAL_MOUNT" || true
echo

# Detect a real Global Volume at /workspace-global.
HAS_GLOBAL=0

if [ -d "$GLOBAL_MOUNT" ] && [ -w "$GLOBAL_MOUNT" ]; then
    ROOT_SOURCE="$(findmnt -T / -n -o SOURCE 2>/dev/null || true)"
    GLOBAL_SOURCE="$(findmnt -T "$GLOBAL_MOUNT" -n -o SOURCE 2>/dev/null || true)"
    ROOT_DEVICE="$(df -P / 2>/dev/null | awk 'NR==2 {print $1}' || true)"
    GLOBAL_DEVICE="$(df -P "$GLOBAL_MOUNT" 2>/dev/null | awk 'NR==2 {print $1}' || true)"

    if { [ -n "$GLOBAL_SOURCE" ] && [ "$GLOBAL_SOURCE" != "$ROOT_SOURCE" ]; } || \
       { [ -n "$GLOBAL_DEVICE" ] && [ "$GLOBAL_DEVICE" != "$ROOT_DEVICE" ]; } || \
       mountpoint -q "$GLOBAL_MOUNT" 2>/dev/null; then
        HAS_GLOBAL=1
    fi
fi

if [ "$HAS_GLOBAL" -eq 1 ]; then
    mkdir -p "$GLOBAL_MODELS"

    echo "=== Storage ==="
    echo "Mode: GLOBAL MODEL CACHE"
    echo "Global mount: $GLOBAL_MOUNT"
    echo "Managed cache: $GLOBAL_MODELS"
    echo "Active model location: LOCAL NVMe"
    echo "[OK] Global cache survives Pod termination."
    echo "[OK] Large safetensors are copied to local NVMe before ComfyUI loads them."
    echo

    export CHUD_GLOBAL_MODELS="$GLOBAL_MODELS"
    export CHUD_LOCAL_MODELS="$LOCAL_MODELS"

    "$VENV/bin/python" - <<'PY'
import os
from pathlib import Path

from safetensors import safe_open

GLOBAL_MOUNT = Path("/workspace-global")
GLOBAL_ROOT = Path(os.environ["CHUD_GLOBAL_MODELS"])
LOCAL_ROOT = Path(os.environ["CHUD_LOCAL_MODELS"])
STATUS_PATH = Path("/tmp/chud-v1.5-cache-status.tsv")

# rel_path, expected tensor count, conservative minimum GiB
MODELS = [
    ("diffusion_models/Wan2_1-I2V-14B-480p_fp8_e5m2_scaled_KJ.safetensors", 1784, 15.0),
    ("diffusion_models/Wan2_1-InfiniteTalk-Single_fp8_e4m3fn_scaled_KJ.safetensors", 451, 2.3),
    ("diffusion_models/MelBandRoformer_fp32.safetensors", 684, 0.7),
    ("loras/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors", 1749, 0.5),
    ("text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors", 412, 5.5),
    ("clip_vision/clip_vision_h.safetensors", 521, 1.0),
    ("vae/wan_2.1_vae.safetensors", 194, 0.15),
    ("wav2vec2/wav2vec2-chinese-base_fp16.safetensors", 218, 0.10),
]

def gib(path: Path) -> float:
    return path.stat().st_size / (1024 ** 3)

def plausible(path: Path, min_gib: float) -> bool:
    try:
        return path.is_file() and gib(path) >= min_gib
    except OSError:
        return False

def validate_local(path: Path, expected_tensors: int, min_gib: float):
    if not plausible(path, min_gib):
        return False, "missing/too small"

    try:
        with safe_open(str(path), framework="pt", device="cpu") as f:
            count = len(list(f.keys()))

        if count != expected_tensors:
            return False, f"{count} tensors; expected {expected_tensors}"

        return True, f"{gib(path):.2f} GiB / {count} tensors"
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"

def copy_global_to_local(src: Path, dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)

    tmp = dst.with_name(dst.name + ".global.tmp")
    tmp.unlink(missing_ok=True)

    total = src.stat().st_size
    done = 0
    next_pct = 10

    print(f"[GLOBAL -> LOCAL] {src}", flush=True)

    with src.open("rb", buffering=0) as fi, tmp.open("wb", buffering=0) as fo:
        while True:
            chunk = fi.read(64 * 1024 * 1024)
            if not chunk:
                break

            fo.write(chunk)
            done += len(chunk)

            pct = int(done * 100 / total)
            while pct >= next_pct and next_pct <= 90:
                print(
                    f"[COPY] {dst.name}: {next_pct}% "
                    f"({done/(1024**3):.2f}/{total/(1024**3):.2f} GiB)",
                    flush=True,
                )
                next_pct += 10

        fo.flush()
        os.fsync(fo.fileno())

    os.replace(tmp, dst)
    print(f"[COPY] {dst.name}: 100%", flush=True)

# Scan the existing volume once. This also lets V1.5 reuse files already
# stored by an older setup without moving or deleting unknown user data.
print("[GLOBAL] Scanning existing Global Volume for known safetensors...", flush=True)

basename_index = {}

for root, dirs, files in os.walk(GLOBAL_MOUNT):
    dirs[:] = [d for d in dirs if d not in {".cache", "__pycache__"}]

    for name in files:
        if name.endswith(".safetensors"):
            basename_index.setdefault(name, Path(root) / name)

print(f"[GLOBAL] Found {len(basename_index)} safetensors filenames.", flush=True)

states = []

for i, (rel_s, expected_tensors, min_gib) in enumerate(MODELS, 1):
    rel = Path(rel_s)
    local = LOCAL_ROOT / rel
    canonical = GLOBAL_ROOT / rel
    basename = local.name

    print("", flush=True)
    print("=" * 80, flush=True)
    print(f"[{i}/{len(MODELS)}] {basename}", flush=True)
    print("=" * 80, flush=True)

    # If local already exists and validates, downloader can skip it.
    ok, detail = validate_local(local, expected_tensors, min_gib)
    if ok:
        print(f"[LOCAL HIT] {detail}", flush=True)
        states.append((rel_s, "LOCAL"))
        continue

    if local.exists():
        print(f"[LOCAL BAD] {detail}; removing.", flush=True)
        local.unlink(missing_ok=True)

    candidates = []

    if plausible(canonical, min_gib):
        candidates.append(canonical)

    old_candidate = basename_index.get(basename)

    if (
        old_candidate is not None
        and old_candidate not in candidates
        and plausible(old_candidate, min_gib)
    ):
        candidates.append(old_candidate)

    copied = False

    for source in candidates:
        print(f"[GLOBAL HIT] Trying {source}", flush=True)

        try:
            copy_global_to_local(source, local)

            ok, detail = validate_local(local, expected_tensors, min_gib)

            if ok:
                print(f"[LOCAL VALID] {detail}", flush=True)
                states.append((rel_s, "GLOBAL"))
                copied = True
                break

            print(f"[GLOBAL COPY BAD] {detail}", flush=True)
            local.unlink(missing_ok=True)

        except Exception as e:
            print(f"[GLOBAL READ ERROR] {type(e).__name__}: {e}", flush=True)
            local.unlink(missing_ok=True)

    if not copied:
        print("[CACHE MISS] This model will be downloaded with hf_xet.", flush=True)
        states.append((rel_s, "MISS"))

with STATUS_PATH.open("w", encoding="utf-8") as f:
    for rel_s, state in states:
        f.write(f"{rel_s}\t{state}\n")

print("", flush=True)
print("[GLOBAL] Prefill phase complete.", flush=True)
PY

else
    echo "=== Storage ==="
    echo "Mode: LOCAL ONLY"
    echo "[INFO] No Global Volume detected at /workspace-global."
    echo "[INFO] Falling back to V1.4 behavior: hf_xet -> local NVMe."
    echo
fi

# Proven V1.1 downloader:
# - validates any cache files already copied to local NVMe
# - skips valid files
# - downloads only missing/corrupt models
# - validates every final safetensors file
echo "=== Model Verification / Download ==="
bash "$DOWNLOADER"

# After the local model set is valid, seed only cache misses into our
# dedicated managed Global Volume directory.
if [ "$HAS_GLOBAL" -eq 1 ]; then
    "$VENV/bin/python" - <<'PY'
import os
from pathlib import Path

GLOBAL_ROOT = Path(os.environ["CHUD_GLOBAL_MODELS"])
LOCAL_ROOT = Path(os.environ["CHUD_LOCAL_MODELS"])
STATUS_PATH = Path("/tmp/chud-v1.5-cache-status.tsv")

def copy_local_to_global(src: Path, dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)

    tmp = dst.with_name(dst.name + ".seed.tmp")
    tmp.unlink(missing_ok=True)

    total = src.stat().st_size
    done = 0
    next_pct = 10

    print(f"[LOCAL -> GLOBAL] {src}", flush=True)

    with src.open("rb", buffering=0) as fi, tmp.open("wb", buffering=0) as fo:
        while True:
            chunk = fi.read(64 * 1024 * 1024)
            if not chunk:
                break

            fo.write(chunk)
            done += len(chunk)

            pct = int(done * 100 / total)
            while pct >= next_pct and next_pct <= 90:
                print(
                    f"[SEED] {dst.name}: {next_pct}% "
                    f"({done/(1024**3):.2f}/{total/(1024**3):.2f} GiB)",
                    flush=True,
                )
                next_pct += 10

        fo.flush()
        os.fsync(fo.fileno())

    os.replace(tmp, dst)
    print(f"[SEED] {dst.name}: 100%", flush=True)

seed_failures = []

if STATUS_PATH.exists():
    for line in STATUS_PATH.read_text(encoding="utf-8").splitlines():
        rel_s, state = line.split("\t", 1)

        if state != "MISS":
            continue

        rel = Path(rel_s)
        src = LOCAL_ROOT / rel
        dst = GLOBAL_ROOT / rel

        if not src.is_file():
            seed_failures.append(f"{rel_s}: validated local source missing")
            continue

        print("", flush=True)
        print(f"[CACHE SEED] {rel.name}", flush=True)

        try:
            copy_local_to_global(src, dst)
        except Exception as e:
            seed_failures.append(f"{rel_s}: {type(e).__name__}: {e}")
            print(f"[CACHE SEED WARNING] {type(e).__name__}: {e}", flush=True)

print("", flush=True)

if seed_failures:
    print("[WARNING] Current Pod is usable, but some Global cache writes failed:", flush=True)
    for item in seed_failures:
        print(f"  - {item}", flush=True)
else:
    print("[OK] Global model cache is ready for future Pods.", flush=True)
PY
fi

echo
echo "=== Workflow Check ==="
WORKFLOW="$COMFY/user/default/workflows/infinitetalk.json"
"$VENV/bin/python" -m json.tool "$WORKFLOW" >/dev/null
echo "[OK] Stable InfiniteTalk workflow ready."

echo
echo "=== Final Runtime Check ==="
"$VENV/bin/python" - <<'PY'
import ctypes
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

print("torch:", torch.__version__)
print("torch CUDA:", torch.version.cuda)
print("GPU:", torch.cuda.get_device_name(device))
print("transformers:", transformers.__version__)
print("diffusers:", diffusers.__version__)
print("huggingface_hub:", huggingface_hub.__version__)
print("hf_xet: READY")
print("safetensors:", safetensors.__version__)
print("CUDA compute: PASS")
print("ChuD V1.5.1 runtime check: PASS")
PY

echo
echo "================================================"
echo " ChuD InfiniteTalk V1.5.1 READY                "
echo " Runtime: Docker image                         "

if [ "$HAS_GLOBAL" -eq 1 ]; then
    echo " Persistent model cache: Global Volume         "
else
    echo " Persistent model cache: NONE                  "
fi

echo " Active models: local NVMe                     "
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

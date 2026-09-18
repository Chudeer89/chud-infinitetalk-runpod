#!/bin/bash
set -euo pipefail

echo "================================================"
echo " ChuD InfiniteTalk One-Click Public V1.3       "
echo " Global Model Cache + hf_xet High Performance "
echo "================================================"

V11_REF="bdeedb520d69d97cc53c96a46278d7ba9f769058"
V11_RAW="https://raw.githubusercontent.com/Chudeer89/chud-infinitetalk-runpod/${V11_REF}"

EPHEMERAL_BASE="/opt/chud"
VOLUME_BASE="/workspace/chud"
GLOBAL_ROOT="/workspace-global/chud/infinitetalk"
GLOBAL_MODELS="$GLOBAL_ROOT/models"

BASE="$EPHEMERAL_BASE"
STORAGE_MODE="Ephemeral"
HAS_GLOBAL=0
HAS_VOLUME=0

is_separate_mount() {
    local path="$1"
    [ -d "$path" ] || return 1
    [ -w "$path" ] || return 1

    local root_source path_source root_dev path_dev
    root_source="$(findmnt -T / -n -o SOURCE 2>/dev/null || true)"
    path_source="$(findmnt -T "$path" -n -o SOURCE 2>/dev/null || true)"
    root_dev="$(df -P / 2>/dev/null | awk 'NR==2 {print $1}' || true)"
    path_dev="$(df -P "$path" 2>/dev/null | awk 'NR==2 {print $1}' || true)"

    if [ -n "$path_source" ] && [ "$path_source" != "$root_source" ]; then
        return 0
    fi
    if [ -n "$path_dev" ] && [ "$path_dev" != "$root_dev" ]; then
        return 0
    fi
    mountpoint -q "$path" 2>/dev/null
}

if is_separate_mount /workspace-global; then
    HAS_GLOBAL=1
    STORAGE_MODE="Global Cache"
    BASE="$EPHEMERAL_BASE"
    mkdir -p "$GLOBAL_MODELS"
elif is_separate_mount /workspace; then
    HAS_VOLUME=1
    STORAGE_MODE="Persistent /workspace"
    BASE="$EPHEMERAL_BASE"
    mkdir -p "$VOLUME_BASE"

    if [ -e "$EPHEMERAL_BASE" ] && [ ! -L "$EPHEMERAL_BASE" ]; then
        if find "$EPHEMERAL_BASE" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
            echo "[STORAGE] Migrating existing $EPHEMERAL_BASE to $VOLUME_BASE ..."
            cp -a "$EPHEMERAL_BASE"/. "$VOLUME_BASE"/
        fi
        rm -rf "$EPHEMERAL_BASE"
    elif [ -L "$EPHEMERAL_BASE" ]; then
        rm -f "$EPHEMERAL_BASE"
    fi

    ln -s "$VOLUME_BASE" "$EPHEMERAL_BASE"
else
    if [ -L "$EPHEMERAL_BASE" ] && [ ! -e "$EPHEMERAL_BASE" ]; then
        rm -f "$EPHEMERAL_BASE"
    fi
    mkdir -p "$EPHEMERAL_BASE"
fi

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
echo "Runtime root: $BASE"
echo "HF_XET_HIGH_PERFORMANCE=$HF_XET_HIGH_PERFORMANCE"
echo "HF_HOME=$HF_HOME"

if [ "$HAS_GLOBAL" -eq 1 ]; then
    echo "Global cache root: $GLOBAL_ROOT"
    echo "[OK] Models persist across Pod termination and regions."
    echo "[OK] Models are copied to local NVMe before ComfyUI loads them."
elif [ "$HAS_VOLUME" -eq 1 ]; then
    echo "Persistent root: $VOLUME_BASE"
    echo "[OK] Runtime, models and HF cache persist with this volume."
else
    echo "[INFO] No persistent storage detected."
    echo "[INFO] Running in V1.1-compatible ephemeral mode."
fi

echo
echo "=== GPU ==="
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || true
VRAM="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)"
if [ "${VRAM:-0}" -lt 30000 ]; then
    echo "[WARNING] ChuD InfiniteTalk is tested for GPUs with ~32 GB VRAM or more."
    echo "[WARNING] Detected VRAM: ${VRAM:-unknown} MB"
fi

echo
echo "=== Disk ==="
df -h /opt || true
[ -d /workspace ] && df -h /workspace || true
[ -d /workspace-global ] && df -h /workspace-global || true

NEED_RUNTIME=0
[ -f "$RUNTIME_MARKER" ] || NEED_RUNTIME=1
[ -x "$VENV/bin/python" ] || NEED_RUNTIME=1
[ -d "$COMFY/.git" ] || NEED_RUNTIME=1

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
    curl -fL --retry 10 --retry-delay 3 "$V11_RAW/install.sh" -o /tmp/chud-install.sh
    bash /tmp/chud-install.sh
    touch "$RUNTIME_MARKER"
    echo "[OK] Runtime installed."
else
    echo
echo "[OK] Runtime already installed. Skipping reinstall."
fi

echo
echo "=== Checking InfiniteTalk Models ==="

if [ "$HAS_GLOBAL" -eq 1 ]; then
    export CHUD_GLOBAL_MODELS="$GLOBAL_MODELS"
    export CHUD_LOCAL_MODELS="$COMFY/models"

    "$VENV/bin/python" - <<'PY'
import os
import shutil
import time
from pathlib import Path
from huggingface_hub import hf_hub_download
from safetensors import safe_open

GLOBAL_ROOT = Path(os.environ["CHUD_GLOBAL_MODELS"])
LOCAL_ROOT = Path(os.environ["CHUD_LOCAL_MODELS"])
GLOBAL_ROOT.mkdir(parents=True, exist_ok=True)
LOCAL_ROOT.mkdir(parents=True, exist_ok=True)

MODELS = [
    ("diffusion_models/Wan2_1-I2V-14B-480p_fp8_e5m2_scaled_KJ.safetensors", "Kijai/WanVideo_comfy_fp8_scaled", "I2V/Wan2_1-I2V-14B-480p_fp8_e5m2_scaled_KJ.safetensors", 1784, 15.0),
    ("diffusion_models/Wan2_1-InfiniteTalk-Single_fp8_e4m3fn_scaled_KJ.safetensors", "Kijai/WanVideo_comfy_fp8_scaled", "InfiniteTalk/Wan2_1-InfiniteTalk-Single_fp8_e4m3fn_scaled_KJ.safetensors", 451, 2.3),
    ("diffusion_models/MelBandRoformer_fp32.safetensors", "Kijai/MelBandRoFormer_comfy", "MelBandRoformer_fp32.safetensors", 684, 0.7),
    ("loras/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors", "Kijai/WanVideo_comfy", "Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors", 1749, 0.5),
    ("text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors", "Comfy-Org/Wan_2.1_ComfyUI_repackaged", "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors", 412, 5.5),
    ("clip_vision/clip_vision_h.safetensors", "Comfy-Org/Wan_2.1_ComfyUI_repackaged", "split_files/clip_vision/clip_vision_h.safetensors", 521, 1.0),
    ("vae/wan_2.1_vae.safetensors", "Comfy-Org/Wan_2.1_ComfyUI_repackaged", "split_files/vae/wan_2.1_vae.safetensors", 194, 0.15),
    ("wav2vec2/wav2vec2-chinese-base_fp16.safetensors", "Kijai/wav2vec2_safetensors", "wav2vec2-chinese-base_fp16.safetensors", 218, 0.10),
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
            return False, f"tensor count {count} != {expected_tensors}"
        return True, f"{gib(path):.2f} GiB / {count} tensors"
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"

def copy_with_progress(src: Path, dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".tmp")
    tmp.unlink(missing_ok=True)
    total = src.stat().st_size
    done = 0
    next_pct = 10
    print(f"[COPY] {src} -> {dst}", flush=True)
    with src.open("rb", buffering=0) as fi, tmp.open("wb", buffering=0) as fo:
        while True:
            block = fi.read(64 * 1024 * 1024)
            if not block:
                break
            fo.write(block)
            done += len(block)
            pct = int(done * 100 / total)
            if pct >= next_pct:
                print(f"[COPY] {dst.name}: {pct}% ({done/(1024**3):.2f}/{total/(1024**3):.2f} GiB)", flush=True)
                next_pct += 10
        fo.flush()
        os.fsync(fo.fileno())
    os.replace(tmp, dst)
    print(f"[COPY] {dst.name}: 100%", flush=True)

print("[GLOBAL] Scanning existing Global Volume once...", flush=True)
basename_index = {}
for root, dirs, files in os.walk(Path("/workspace-global")):
    dirs[:] = [d for d in dirs if d not in {".cache", "__pycache__"}]
    for name in files:
        if name.endswith(".safetensors"):
            basename_index.setdefault(name, Path(root) / name)
print(f"[GLOBAL] Found {len(basename_index)} safetensors basenames.", flush=True)

for i, (rel_s, repo, filename, tensor_count, min_gib) in enumerate(MODELS, 1):
    rel = Path(rel_s)
    local = LOCAL_ROOT / rel
    canonical = GLOBAL_ROOT / rel
    basename = local.name

    print("", flush=True)
    print("=" * 80, flush=True)
    print(f"[{i}/{len(MODELS)}] {basename}", flush=True)
    print("=" * 80, flush=True)

    ok, detail = validate_local(local, tensor_count, min_gib)
    if ok:
        print(f"[LOCAL OK] {detail}", flush=True)
        if not plausible(canonical, min_gib):
            print("[GLOBAL] Canonical cache missing; seeding it from validated local copy.", flush=True)
            copy_with_progress(local, canonical)
        continue
    elif local.exists():
        print(f"[LOCAL BAD] {detail}; removing local copy.", flush=True)
        local.unlink(missing_ok=True)

    source = None
    if plausible(canonical, min_gib):
        source = canonical
        print(f"[GLOBAL HIT] Canonical cache: {source}", flush=True)
    else:
        candidate = basename_index.get(basename)
        if candidate and plausible(candidate, min_gib):
            source = candidate
            print(f"[GLOBAL HIT] Existing old cache: {source}", flush=True)

    if source is not None:
        copy_with_progress(source, local)
        ok, detail = validate_local(local, tensor_count, min_gib)
        if ok:
            print(f"[LOCAL VALID] {detail}", flush=True)
            continue

        print(f"[GLOBAL COPY INVALID] {detail}", flush=True)
        local.unlink(missing_ok=True)
        try:
            source.relative_to(GLOBAL_ROOT)
            source.unlink(missing_ok=True)
            print("[GLOBAL] Removed invalid managed cache file.", flush=True)
        except ValueError:
            print("[GLOBAL] Old external file left untouched.", flush=True)

    print("[GLOBAL MISS] Downloading once from Hugging Face with hf_xet High Performance.", flush=True)
    last_error = None
    for attempt in range(1, 6):
        try:
            print(f"[DOWNLOAD] Attempt {attempt}/5", flush=True)
            local.parent.mkdir(parents=True, exist_ok=True)
            downloaded = Path(hf_hub_download(repo_id=repo, filename=filename, local_dir=str(local.parent), force_download=(attempt > 1)))
            if downloaded.resolve() != local.resolve():
                tmp_final = local.with_name(local.name + ".from-hf.tmp")
                tmp_final.unlink(missing_ok=True)
                shutil.move(str(downloaded), str(tmp_final))
                os.replace(tmp_final, local)

            ok, detail = validate_local(local, tensor_count, min_gib)
            if not ok:
                raise RuntimeError(f"Downloaded file failed validation: {detail}")

            print(f"[DOWNLOADED + VALID] {detail}", flush=True)
            copy_with_progress(local, canonical)
            print(f"[GLOBAL STORED] {canonical}", flush=True)
            last_error = None
            break
        except Exception as e:
            last_error = e
            print(f"[DOWNLOAD ERROR] {type(e).__name__}: {e}", flush=True)
            local.unlink(missing_ok=True)
            if attempt < 5:
                time.sleep(min(3 * attempt, 12))

    if last_error is not None:
        raise SystemExit(f"Failed model after 5 attempts: {basename}: {last_error}")

print("", flush=True)
print("[OK] All InfiniteTalk models are local-NVMe validated.", flush=True)
print("[OK] Global Volume remains the persistent model cache.", flush=True)
PY
else
    curl -fL --retry 10 --retry-delay 3 "$V11_RAW/download-models.sh" -o /tmp/chud-download-models.sh
    bash /tmp/chud-download-models.sh
fi

touch "$MODELS_MARKER"
echo
echo "[OK] All model files verified."

echo
echo "=== Installing Stable Workflow ==="
mkdir -p "$COMFY/user/default/workflows"
WORKFLOW_TMP="$COMFY/user/default/workflows/infinitetalk.json.tmp"
WORKFLOW_FINAL="$COMFY/user/default/workflows/infinitetalk.json"
rm -f "$WORKFLOW_TMP"
curl -fL --retry 10 --retry-delay 3 "$V11_RAW/infinitetalk%201.json" -o "$WORKFLOW_TMP"
"$VENV/bin/python" -m json.tool "$WORKFLOW_TMP" >/dev/null
mv -f "$WORKFLOW_TMP" "$WORKFLOW_FINAL"
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
echo " ChuD InfiniteTalk V1.3 READY                 "
echo " Storage: $STORAGE_MODE"
if [ "$HAS_GLOBAL" -eq 1 ]; then
    echo " Global model cache: $GLOBAL_ROOT"
    echo " Active models: local NVMe                    "
fi
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
exec "$VENV/bin/python" main.py --listen 0.0.0.0 --port 8188 --enable-cors-header "$CORS"

#!/bin/bash
set -euo pipefail

echo "=========================================="
echo " ChuD InfiniteTalk FAST Model Downloader "
echo " hf_xet High Performance                 "
echo "=========================================="

COMFY="/opt/chud/ComfyUI"
MODELS="$COMFY/models"
STAGE="/opt/chud/hf-stage"

export HF_XET_HIGH_PERFORMANCE=1
export HF_HUB_DISABLE_XET=0
export HF_HOME="/opt/chud/hf-cache"
export PYTHONUNBUFFERED=1

mkdir -p \
  "$MODELS/diffusion_models" \
  "$MODELS/loras" \
  "$MODELS/text_encoders" \
  "$MODELS/clip_vision" \
  "$MODELS/vae" \
  "$MODELS/wav2vec2" \
  "$STAGE"

echo
echo "=== Xet configuration ==="
echo "HF_XET_HIGH_PERFORMANCE=$HF_XET_HIGH_PERFORMANCE"
echo "HF_HOME=$HF_HOME"

"$VIRTUAL_ENV/bin/python" - <<'PY'
import os
import shutil
import time
from pathlib import Path

from huggingface_hub import hf_hub_download
from safetensors import safe_open

MODELS = Path("/opt/chud/ComfyUI/models")
STAGE = Path("/opt/chud/hf-stage")

FILES = [
    {
        "repo": "Kijai/WanVideo_comfy_fp8_scaled",
        "filename": "I2V/Wan2_1-I2V-14B-480p_fp8_e5m2_scaled_KJ.safetensors",
        "dest": MODELS / "diffusion_models" / "Wan2_1-I2V-14B-480p_fp8_e5m2_scaled_KJ.safetensors",
    },
    {
        "repo": "Kijai/WanVideo_comfy_fp8_scaled",
        "filename": "InfiniteTalk/Wan2_1-InfiniteTalk-Single_fp8_e4m3fn_scaled_KJ.safetensors",
        "dest": MODELS / "diffusion_models" / "Wan2_1-InfiniteTalk-Single_fp8_e4m3fn_scaled_KJ.safetensors",
    },
    {
        "repo": "Kijai/MelBandRoFormer_comfy",
        "filename": "MelBandRoformer_fp32.safetensors",
        "dest": MODELS / "diffusion_models" / "MelBandRoformer_fp32.safetensors",
    },
    {
        "repo": "Kijai/WanVideo_comfy",
        "filename": "Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors",
        "dest": MODELS / "loras" / "lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors",
    },
    {
        "repo": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
        "filename": "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
        "dest": MODELS / "text_encoders" / "umt5_xxl_fp8_e4m3fn_scaled.safetensors",
    },
    {
        "repo": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
        "filename": "split_files/clip_vision/clip_vision_h.safetensors",
        "dest": MODELS / "clip_vision" / "clip_vision_h.safetensors",
    },
    {
        "repo": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
        "filename": "split_files/vae/wan_2.1_vae.safetensors",
        "dest": MODELS / "vae" / "wan_2.1_vae.safetensors",
    },
    {
        "repo": "Kijai/wav2vec2_safetensors",
        "filename": "wav2vec2-chinese-base_fp16.safetensors",
        "dest": MODELS / "wav2vec2" / "wav2vec2-chinese-base_fp16.safetensors",
    },
]

def validate(path: Path):
    if not path.exists() or path.stat().st_size == 0:
        return False, "file missing or empty"

    try:
        with safe_open(str(path), framework="pt", device="cpu") as f:
            count = len(f.keys())

        if count == 0:
            return False, "no tensors found"

        return True, f"{count} tensors"

    except Exception as e:
        return False, str(e)


def download_one(item):
    repo = item["repo"]
    filename = item["filename"]
    dest = item["dest"]

    dest.parent.mkdir(parents=True, exist_ok=True)

    print()
    print("=" * 72)
    print(f"MODEL: {dest.name}")
    print(f"REPO : {repo}")
    print("=" * 72)

    # Existing file: validate before skipping
    if dest.exists():
        ok, msg = validate(dest)

        if ok:
            gb = dest.stat().st_size / (1024 ** 3)
            print(f"[OK] Existing file valid: {gb:.2f} GiB | {msg}")
            return

        print(f"[BAD] Existing file is corrupt: {msg}")
        print("[ACTION] Removing corrupt file...")
        dest.unlink(missing_ok=True)

    for attempt in range(1, 6):
        print()
        print(f"[DOWNLOAD] Attempt {attempt}/5")
        print("[MODE] hf_xet High Performance")

        try:
            downloaded = Path(
                hf_hub_download(
                    repo_id=repo,
                    filename=filename,
                    local_dir=str(STAGE),
                    force_download=(attempt > 1),
                )
            )

            print(f"[DOWNLOADED] {downloaded}")

            ok, msg = validate(downloaded)

            if not ok:
                print(f"[BAD] Validation failed: {msg}")
                downloaded.unlink(missing_ok=True)
                time.sleep(5)
                continue

            gb = downloaded.stat().st_size / (1024 ** 3)
            print(f"[VALID] {gb:.2f} GiB | {msg}")

            tmp_dest = dest.with_suffix(dest.suffix + ".tmp")
            tmp_dest.unlink(missing_ok=True)

            print("[INSTALL] Moving verified file into ComfyUI models...")

            shutil.move(str(downloaded), str(tmp_dest))

            # Validate once more after move
            ok, msg = validate(tmp_dest)

            if not ok:
                print(f"[BAD] Final validation failed: {msg}")
                tmp_dest.unlink(missing_ok=True)
                time.sleep(5)
                continue

            os.replace(tmp_dest, dest)

            print(f"[OK] READY: {dest}")
            return

        except KeyboardInterrupt:
            raise

        except Exception as e:
            print(f"[ERROR] {type(e).__name__}: {e}")

            if attempt < 5:
                print("[RETRY] Waiting 10 seconds...")
                time.sleep(10)

    raise RuntimeError(
        f"Failed to download a valid copy after 5 attempts: {dest.name}"
    )


for item in FILES:
    download_one(item)


print()
print("=" * 72)
print("FINAL SAFETENSORS VALIDATION")
print("=" * 72)

bad = []

for item in FILES:
    dest = item["dest"]
    ok, msg = validate(dest)

    if ok:
        gb = dest.stat().st_size / (1024 ** 3)
        print(f"[OK]  {dest.name:75} {gb:6.2f} GiB | {msg}")
    else:
        print(f"[BAD] {dest.name}: {msg}")
        bad.append(str(dest))

if bad:
    print()
    print("BAD FILES:")
    for path in bad:
        print(path)
    raise SystemExit(1)

print()
print("=============================================")
print(" ALL INFINITETALK MODELS VERIFIED AND READY ")
print("=============================================")
PY

rm -rf "$STAGE"

echo
echo "=== ChuD InfiniteTalk models ready ==="

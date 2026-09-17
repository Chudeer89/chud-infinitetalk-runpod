#!/bin/bash
set -euo pipefail

echo "=============================================="
echo " ChuD InfiniteTalk FAST Model Downloader V1.1 "
echo " hf_xet High Performance                      "
echo "=============================================="

BASE="/opt/chud"
COMFY="$BASE/ComfyUI"
VENV="$BASE/venv"
MODELS="$COMFY/models"

HF_CACHE="$BASE/hf-cache"
STAGE="$BASE/hf-stage"

# =========================================================
# Hugging Face Xet High Performance
# =========================================================
export HF_XET_HIGH_PERFORMANCE=1
export HF_HUB_DISABLE_XET=0
export HF_HOME="$HF_CACHE"
export PYTHONUNBUFFERED=1

mkdir -p \
    "$MODELS/diffusion_models" \
    "$MODELS/loras" \
    "$MODELS/text_encoders" \
    "$MODELS/clip_vision" \
    "$MODELS/vae" \
    "$MODELS/wav2vec2" \
    "$HF_CACHE" \
    "$STAGE"

echo
echo "=== Downloader configuration ==="
echo "HF_XET_HIGH_PERFORMANCE=$HF_XET_HIGH_PERFORMANCE"
echo "HF_HOME=$HF_HOME"
echo "Models=$MODELS"

# =========================================================
# Check runtime
# =========================================================
"$VENV/bin/python" - <<'PY'
import huggingface_hub
import hf_xet
import safetensors

print("huggingface_hub:", huggingface_hub.__version__)
print("hf_xet: READY")
print("safetensors:", safetensors.__version__)
print("High Performance mode: READY")
PY

# =========================================================
# Download + validate all models
# =========================================================
"$VENV/bin/python" - <<'PY'

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
        "dest": MODELS / "diffusion_models" /
                "Wan2_1-I2V-14B-480p_fp8_e5m2_scaled_KJ.safetensors",
    },

    {
        "repo": "Kijai/WanVideo_comfy_fp8_scaled",
        "filename": "InfiniteTalk/Wan2_1-InfiniteTalk-Single_fp8_e4m3fn_scaled_KJ.safetensors",
        "dest": MODELS / "diffusion_models" /
                "Wan2_1-InfiniteTalk-Single_fp8_e4m3fn_scaled_KJ.safetensors",
    },

    {
        "repo": "Kijai/MelBandRoFormer_comfy",
        "filename": "MelBandRoformer_fp32.safetensors",
        "dest": MODELS / "diffusion_models" /
                "MelBandRoformer_fp32.safetensors",
    },

    {
        "repo": "Kijai/WanVideo_comfy",
        "filename": "Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors",
        "dest": MODELS / "loras" /
                "lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors",
    },

    {
        "repo": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
        "filename": "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
        "dest": MODELS / "text_encoders" /
                "umt5_xxl_fp8_e4m3fn_scaled.safetensors",
    },

    {
        "repo": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
        "filename": "split_files/clip_vision/clip_vision_h.safetensors",
        "dest": MODELS / "clip_vision" /
                "clip_vision_h.safetensors",
    },

    {
        "repo": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
        "filename": "split_files/vae/wan_2.1_vae.safetensors",
        "dest": MODELS / "vae" /
                "wan_2.1_vae.safetensors",
    },

    {
        "repo": "Kijai/wav2vec2_safetensors",
        "filename": "wav2vec2-chinese-base_fp16.safetensors",
        "dest": MODELS / "wav2vec2" /
                "wav2vec2-chinese-base_fp16.safetensors",
    },
]


def validate(path: Path):
    """
    Verify that a safetensors file exists and its tensor metadata
    can be read completely.
    """

    if not path.exists():
        return False, "file does not exist"

    if path.stat().st_size <= 0:
        return False, "file is empty"

    try:
        with safe_open(
            str(path),
            framework="pt",
            device="cpu"
        ) as f:
            keys = list(f.keys())

        if not keys:
            return False, "no tensors found"

        return True, f"{len(keys)} tensors"

    except Exception as e:
        return False, str(e)


def human_size(path: Path):
    return path.stat().st_size / (1024 ** 3)


def download_model(item):

    repo = item["repo"]
    filename = item["filename"]
    dest = item["dest"]

    dest.parent.mkdir(
        parents=True,
        exist_ok=True
    )

    print()
    print("=" * 80)
    print("MODEL :", dest.name)
    print("REPO  :", repo)
    print("SOURCE:", filename)
    print("=" * 80)

    # -----------------------------------------------------
    # Existing model
    # -----------------------------------------------------
    if dest.exists():

        ok, info = validate(dest)

        if ok:
            print(
                f"[OK] Existing model verified "
                f"{human_size(dest):.2f} GiB | {info}"
            )
            return

        print("[BAD] Existing model is corrupt")
        print("Reason:", info)
        print("[ACTION] Removing bad model")

        dest.unlink(missing_ok=True)

    # -----------------------------------------------------
    # Download attempts
    # -----------------------------------------------------
    for attempt in range(1, 6):

        print()
        print(
            f"[DOWNLOAD] Attempt {attempt}/5"
        )

        print(
            "[MODE] hf_xet High Performance"
        )

        try:

            downloaded = Path(
                hf_hub_download(
                    repo_id=repo,
                    filename=filename,
                    local_dir=str(STAGE),
                    force_download=(attempt > 1),
                )
            )

            print(
                "[DOWNLOADED]",
                downloaded
            )

            # ---------------------------------------------
            # Validation before installation
            # ---------------------------------------------
            ok, info = validate(downloaded)

            if not ok:

                print(
                    "[BAD] Downloaded file failed validation"
                )

                print(
                    "Reason:",
                    info
                )

                downloaded.unlink(
                    missing_ok=True
                )

                time.sleep(5)

                continue

            print(
                f"[VALID] "
                f"{human_size(downloaded):.2f} GiB | "
                f"{info}"
            )

            # ---------------------------------------------
            # Atomic installation
            # ---------------------------------------------
            temp_dest = Path(
                str(dest) + ".tmp"
            )

            temp_dest.unlink(
                missing_ok=True
            )

            print(
                "[INSTALL] Installing verified model..."
            )

            shutil.move(
                str(downloaded),
                str(temp_dest)
            )

            # ---------------------------------------------
            # Validate after move
            # ---------------------------------------------
            ok, info = validate(
                temp_dest
            )

            if not ok:

                print(
                    "[BAD] Final validation failed"
                )

                print(
                    "Reason:",
                    info
                )

                temp_dest.unlink(
                    missing_ok=True
                )

                time.sleep(5)

                continue

            # Atomic rename
            os.replace(
                temp_dest,
                dest
            )

            print(
                f"[READY] {dest}"
            )

            return

        except KeyboardInterrupt:
            raise

        except Exception as e:

            print(
                f"[ERROR] "
                f"{type(e).__name__}: {e}"
            )

            if attempt < 5:

                print(
                    "[RETRY] Waiting 10 seconds..."
                )

                time.sleep(10)

    raise RuntimeError(
        f"Could not download a valid copy of "
        f"{dest.name} after 5 attempts"
    )


# =========================================================
# Download models
# =========================================================

for item in FILES:
    download_model(item)


# =========================================================
# Final validation
# =========================================================

print()
print("=" * 80)
print(" FINAL SAFETENSORS VALIDATION")
print("=" * 80)

bad_files = []

for item in FILES:

    dest = item["dest"]

    ok, info = validate(dest)

    if ok:

        print(
            f"[OK] {dest.name}"
        )

        print(
            f"     Size: "
            f"{human_size(dest):.2f} GiB"
        )

        print(
            f"     {info}"
        )

    else:

        print(
            f"[BAD] {dest}"
        )

        print(
            f"      {info}"
        )

        bad_files.append(
            str(dest)
        )


if bad_files:

    print()
    print(
        "ERROR: Corrupt/incomplete models remain:"
    )

    for path in bad_files:
        print(path)

    raise SystemExit(1)


print()
print("==============================================")
print(" ALL INFINITETALK MODELS VERIFIED AND READY ")
print("==============================================")

PY

# =========================================================
# Cleanup temporary staging directory
# Keep HF cache for resume/reuse while Pod exists
# =========================================================

rm -rf "$STAGE"

echo
echo "=========================================="
echo " ChuD InfiniteTalk Models READY           "
echo " hf_xet High Performance COMPLETE         "
echo "=========================================="

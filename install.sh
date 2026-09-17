#!/bin/bash
set -euo pipefail

echo "=========================================="
echo " ChuD InfiniteTalk Public V1.1 Installer "
echo " hf_xet High Performance Ready           "
echo "=========================================="

BASE="/opt/chud"
COMFY="$BASE/ComfyUI"
VENV="$BASE/venv"

# =========================================================
# System packages
# =========================================================
apt-get update

apt-get install -y \
    git \
    curl \
    wget \
    ffmpeg

rm -rf /var/lib/apt/lists/*

mkdir -p "$BASE"

# =========================================================
# Python environment
# =========================================================
if [ ! -d "$VENV" ]; then
    python3 -m venv --system-site-packages "$VENV"
fi

"$VENV/bin/pip" install --upgrade \
    pip \
    setuptools \
    wheel

# =========================================================
# ComfyUI Stable
# =========================================================
if [ ! -d "$COMFY/.git" ]; then
    git clone \
        https://github.com/Comfy-Org/ComfyUI.git \
        "$COMFY"
fi

git -C "$COMFY" fetch --all

git -C "$COMFY" checkout \
    7a0b5eede3f9721c8faab290689893f36edc6d66

"$VENV/bin/pip" install \
    -r "$COMFY/requirements.txt"

mkdir -p "$COMFY/custom_nodes"

# =========================================================
# WanVideoWrapper Stable
# =========================================================
WAN="$COMFY/custom_nodes/ComfyUI-WanVideoWrapper"

if [ ! -d "$WAN/.git" ]; then
    git clone \
        https://github.com/kijai/ComfyUI-WanVideoWrapper.git \
        "$WAN"
fi

git -C "$WAN" fetch --all

git -C "$WAN" checkout \
    088128b224242e110d3906c6750e9a3a348a659b

if [ -f "$WAN/requirements.txt" ]; then
    "$VENV/bin/pip" install \
        -r "$WAN/requirements.txt"
fi

# =========================================================
# KJNodes Stable
# =========================================================
KJ="$COMFY/custom_nodes/ComfyUI-KJNodes"

if [ ! -d "$KJ/.git" ]; then
    git clone \
        https://github.com/kijai/ComfyUI-KJNodes.git \
        "$KJ"
fi

git -C "$KJ" fetch --all

git -C "$KJ" checkout \
    d3cfe21625e5170126ce06fbfcfe1d88108688c3

if [ -f "$KJ/requirements.txt" ]; then
    "$VENV/bin/pip" install \
        -r "$KJ/requirements.txt"
fi

# =========================================================
# MelBandRoFormer Stable
# =========================================================
MEL="$COMFY/custom_nodes/ComfyUI-MelBandRoFormer"

if [ ! -d "$MEL/.git" ]; then
    git clone \
        https://github.com/kijai/ComfyUI-MelBandRoFormer.git \
        "$MEL"
fi

git -C "$MEL" fetch --all

git -C "$MEL" checkout \
    92c86854e6654f4aacc97484471af95c98ea16d4

if [ -f "$MEL/requirements.txt" ]; then
    "$VENV/bin/pip" install \
        -r "$MEL/requirements.txt"
fi

# =========================================================
# Known working Python packages
# + Hugging Face Xet
# =========================================================
"$VENV/bin/pip" install \
    "transformers==4.57.6" \
    "diffusers==0.36.0" \
    "huggingface-hub==0.36.2" \
    "hf-xet==1.6.0" \
    "safetensors"

# =========================================================
# Verify hf_xet runtime
# =========================================================
echo
echo "=== Checking Hugging Face Xet ==="

HF_XET_HIGH_PERFORMANCE=1 \
"$VENV/bin/python" - <<'PY'
import huggingface_hub
import hf_xet
import safetensors

print("huggingface_hub:", huggingface_hub.__version__)
print("hf_xet: READY")
print("safetensors:", safetensors.__version__)
print("HF_XET_HIGH_PERFORMANCE: READY")
PY

# =========================================================
# Stable workflow
# =========================================================
mkdir -p "$COMFY/user/default/workflows"

curl -fL \
"https://raw.githubusercontent.com/Chudeer89/chud-infinitetalk-runpod/main/infinitetalk%201.json" \
-o "$COMFY/user/default/workflows/infinitetalk.json"

python3 -m json.tool \
"$COMFY/user/default/workflows/infinitetalk.json" \
>/dev/null

echo "[OK] Stable workflow installed."

# =========================================================
# Installed versions
# =========================================================
echo
echo "=== Installed Git versions ==="

echo "ComfyUI:"
git -C "$COMFY" rev-parse HEAD

echo "WanVideoWrapper:"
git -C "$WAN" rev-parse HEAD

echo "KJNodes:"
git -C "$KJ" rev-parse HEAD

echo "MelBandRoFormer:"
git -C "$MEL" rev-parse HEAD

echo
echo "=== Installed Python versions ==="

"$VENV/bin/pip" show \
    torch \
    transformers \
    diffusers \
    huggingface-hub \
    hf-xet \
    safetensors \
| grep -E "^(Name|Version):"

echo
echo "=========================================="
echo " ChuD InfiniteTalk runtime READY         "
echo " hf_xet High Performance READY           "
echo "=========================================="

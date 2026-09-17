#!/bin/bash
set -euo pipefail

echo "=== ChuD InfiniteTalk Model Downloader ==="

COMFY="/opt/chud/ComfyUI"
MODELS="$COMFY/models"

mkdir -p \
  "$MODELS/diffusion_models" \
  "$MODELS/loras" \
  "$MODELS/text_encoders" \
  "$MODELS/clip_vision" \
  "$MODELS/vae" \
  "$MODELS/wav2vec2"

download() {
    URL="$1"
    DEST="$2"

    if [ -s "$DEST" ]; then
        echo "[OK] Already exists: $(basename "$DEST")"
        return
    fi

    echo
    echo "[DOWNLOAD] $(basename "$DEST")"

    curl -fL \
      --retry 10 \
      --retry-delay 5 \
      --continue-at - \
      "$URL" \
      -o "$DEST"
}

# Wan 2.1 I2V 14B
download \
"https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/I2V/Wan2_1-I2V-14B-480p_fp8_e5m2_scaled_KJ.safetensors" \
"$MODELS/diffusion_models/Wan2_1-I2V-14B-480p_fp8_e5m2_scaled_KJ.safetensors"

# InfiniteTalk
download \
"https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/InfiniteTalk/Wan2_1-InfiniteTalk-Single_fp8_e4m3fn_scaled_KJ.safetensors" \
"$MODELS/diffusion_models/Wan2_1-InfiniteTalk-Single_fp8_e4m3fn_scaled_KJ.safetensors"

# MelBand RoFormer
download \
"https://huggingface.co/Kijai/MelBandRoFormer_comfy/resolve/main/MelBandRoformer_fp32.safetensors" \
"$MODELS/diffusion_models/MelBandRoformer_fp32.safetensors"

# LightX2V LoRA
download \
"https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors" \
"$MODELS/loras/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"

# UMT5
download \
"https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" \
"$MODELS/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"

# CLIP Vision
download \
"https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" \
"$MODELS/clip_vision/clip_vision_h.safetensors"

# Wan VAE
download \
"https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" \
"$MODELS/vae/wan_2.1_vae.safetensors"

# Wav2Vec2
download \
"https://huggingface.co/Kijai/wav2vec2_safetensors/resolve/main/wav2vec2-chinese-base_fp16.safetensors" \
"$MODELS/wav2vec2/wav2vec2-chinese-base_fp16.safetensors"

echo
echo "=== Model files ==="

du -sh "$MODELS"

find "$MODELS" -type f -name "*.safetensors" -printf "%p\n"

echo
echo "=== ChuD InfiniteTalk models ready ==="

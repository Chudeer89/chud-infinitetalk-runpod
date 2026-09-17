# ChuD InfiniteTalk — Working Environment

Verified working on RunPod.

## Git revisions

- ComfyUI: `7a0b5eede3f9721c8faab290689893f36edc6d66`
- ComfyUI-WanVideoWrapper: `088128b224242e110d3906c6750e9a3a348a659b`
- ComfyUI-KJNodes: `d3cfe21625e5170126ce06fbfcfe1d88108688c3`
- ComfyUI-MelBandRoFormer: `92c86854e6654f4aacc97484471af95c98ea16d4`

## Python packages

- torch: `2.8.0+cu128`
- transformers: `4.57.6`
- diffusers: `0.36.0`
- huggingface_hub: `0.36.2`

## Runtime notes

- Base image: `runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404`
- ComfyUI port: `8188`
- Use SDPA / PyTorch attention
- Do not require SageAttention
- Large Wan / InfiniteTalk models should load from Pod local SSD

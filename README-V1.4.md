# ChuD InfiniteTalk V1.4 Docker Runtime

Add these files to the existing repository:

- Dockerfile
- docker-start.sh
- .dockerignore
- .github/workflows/docker-v1.4.yml

Keep the existing install.sh, download-models.sh, infinitetalk 1.json and V1.3 start.sh unchanged.

The GitHub Actions build publishes:

ghcr.io/chudeer89/chud-infinitetalk:1.4

V1.4 bakes the tested runtime into Docker and downloads only the model files at Pod startup via hf_xet.

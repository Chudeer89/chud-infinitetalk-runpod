FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404

ARG DEBIAN_FRONTEND=noninteractive

ENV HF_XET_HIGH_PERFORMANCE=1 \
    HF_HUB_DISABLE_XET=0 \
    HF_HOME=/opt/chud/hf-cache \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

COPY install.sh /tmp/chud-install.sh
COPY download-models.sh /opt/chud/download-models.sh
COPY docker-start.sh /opt/chud/docker-start.sh
COPY ["infinitetalk 1.json", "/tmp/infinitetalk.json"]

RUN chmod +x \
        /tmp/chud-install.sh \
        /opt/chud/download-models.sh \
        /opt/chud/docker-start.sh \
    && bash /tmp/chud-install.sh \
    && mkdir -p /opt/chud/ComfyUI/user/default/workflows \
    && cp /tmp/infinitetalk.json /opt/chud/ComfyUI/user/default/workflows/infinitetalk.json \
    && /opt/chud/venv/bin/python -m json.tool \
        /opt/chud/ComfyUI/user/default/workflows/infinitetalk.json >/dev/null \
    && touch /opt/chud/.runtime-v1.4-image \
    && rm -f /tmp/chud-install.sh /tmp/infinitetalk.json \
    && rm -rf /root/.cache/pip /tmp/pip-* /var/lib/apt/lists/*

WORKDIR /opt/chud/ComfyUI

EXPOSE 8188

CMD ["/opt/chud/docker-start.sh"]

# OpenClaw chat gateway image — runs the Microsoft Teams bot for the triage workflow.
#
# Pinned to 2026.5.7 across core + plugins (see memory:
# feedback_openclaw_plugin_version_pinning — newer @openclaw/* plugins
# require a matching core version; DefenseClaw 0.5.0 sidecar is not
# compatible with anything newer than 2026.5.7 yet).
#
# State lives in /openclaw/.openclaw (HOME=/openclaw for uid 10001). Mount
# a PVC there in the k8s manifest so config, devices, and sessions survive
# pod restarts.
FROM node:24-bookworm-slim

# Runtime dependencies: ca-certs for TLS, curl for fetching the DefenseClaw
# plugin tarball at build time, python3 for the entrypoint's idempotent
# JSON edits.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl python3 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# OpenClaw core + msteams plugin, both pinned.
RUN npm install -g \
      openclaw@2026.5.7 \
      @openclaw/msteams@2026.5.7 \
 && npm cache clean --force

# DefenseClaw OpenClaw plugin (not on npm — comes from the Cisco GitHub release).
# Staged at /opt; the entrypoint copies it into ~/.openclaw/extensions on first boot.
ARG DEFENSECLAW_VERSION=0.5.0
RUN mkdir -p /opt/defenseclaw-plugin \
 && curl -fsSL "https://github.com/cisco-ai-defense/defenseclaw/releases/download/${DEFENSECLAW_VERSION}/defenseclaw-plugin-${DEFENSECLAW_VERSION}.tar.gz" \
    | tar -xz -C /opt/defenseclaw-plugin

# Non-root user. HOME=/openclaw so ~/.openclaw resolves to /openclaw/.openclaw,
# which is the PVC mount point.
RUN useradd --create-home --home-dir /openclaw --uid 10001 --shell /bin/bash openclaw \
 && mkdir -p /openclaw/.openclaw/extensions \
 && chown -R openclaw:openclaw /openclaw

COPY openclaw-entrypoint.sh /usr/local/bin/entrypoint.sh
# Task #29: in-pod sidecar token mirror, runs from the entrypoint on every
# pod start. Replaces the manual fix-sidecar-pairing.py kubectl-exec step.
COPY sidecar-token-mirror.py /usr/local/bin/sidecar-token-mirror.py
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/sidecar-token-mirror.py

USER openclaw
WORKDIR /openclaw

# 18789 = gateway WebSocket (DefenseClaw sidecar connects here)
# 3978  = msteams plugin (Teams bot framework POSTs here via Cilium Gateway)
EXPOSE 18789 3978

# Stdout/stderr unbuffered so the OTel DaemonSet picks up logs promptly.
ENV NODE_OPTIONS="--unhandled-rejections=warn"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

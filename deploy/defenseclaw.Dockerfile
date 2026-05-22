# DefenseClaw sidecar image — Go gateway binary that inspects LLM traffic
# and tool calls for the OpenClaw pod it sits alongside.
#
# Connects out to the OpenClaw gateway's WebSocket (ws://127.0.0.1:18789),
# listens locally on :4000 (guardrail proxy) and :18970 (sidecar REST API).
# State (audit DB, configs) lives in /defenseclaw/.defenseclaw — mount a PVC
# there in the k8s manifest.
#
# Optional MCP proxy (B′-2, task #34): if MCP_PROXY_ENABLED=true, the
# entrypoint also launches mcp_proxy.py which exposes a FastMCP SSE server
# on :8788. Used by the triage agent's sidecar to govern Splunk tool calls.
# kl-openclaw pod leaves it disabled (default).
FROM debian:bookworm-slim

# Base deps + Python 3 (for the MCP proxy) + Node 20 (so the proxy can
# spawn `npx mcp-remote` to reach prod-telemetry upstream).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
      python3 \
      python3-venv \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Pre-install mcp-remote globally so `npx mcp-remote ...` finds it in PATH
# instantly (no npm-registry roundtrip per invocation). Without this, the
# proxy's per-call subprocess design pays ~3-4s of npm download overhead
# on every Splunk query. Pinned to a known-working version because
# mcp-remote bumps frequently and we want reproducible builds.
RUN npm install -g mcp-remote@0.1.37 \
 && npm cache clean --force

# DefenseClaw Go gateway. Pinned because nothing newer is released yet that
# is compatible with OpenClaw 2026.5.7 (see memory:
# feedback_openclaw_plugin_version_pinning).
ARG DEFENSECLAW_VERSION=0.5.0
RUN curl -fsSL "https://github.com/cisco-ai-defense/defenseclaw/releases/download/${DEFENSECLAW_VERSION}/defenseclaw_${DEFENSECLAW_VERSION}_linux_amd64.tar.gz" \
    -o /tmp/dc.tgz \
 && tar -xzf /tmp/dc.tgz -C /tmp \
 && mv /tmp/defenseclaw /usr/local/bin/defenseclaw-gateway \
 && chmod +x /usr/local/bin/defenseclaw-gateway \
 && rm -rf /tmp/dc.tgz /tmp/LICENSE /tmp/CHANGELOG.md /tmp/README.md

# MCP proxy: isolated venv at /opt/mcp-proxy-venv. mcp[cli] pulls in the
# Python MCP SDK with FastMCP server + stdio client we use in mcp_proxy.py.
# cryptography is for task #29's sidecar-identity-derive.py — needs Ed25519
# private-key parsing and public-key derivation that aren't in the stdlib.
RUN python3 -m venv /opt/mcp-proxy-venv \
 && /opt/mcp-proxy-venv/bin/pip install --no-cache-dir --upgrade pip \
 && /opt/mcp-proxy-venv/bin/pip install --no-cache-dir \
      'mcp[cli]>=1.0.0' \
      'cryptography>=42'

COPY mcp_proxy.py /usr/local/bin/mcp_proxy.py
# Task #29: pre-computes the sidecar's identity (deviceId + publicKey + token)
# from device.key + .env, writes JSON for the openclaw container to consume.
COPY sidecar-identity-derive.py /usr/local/bin/sidecar-identity-derive.py
# Task #30: guardrail enable config + initial runtime mode. Entrypoint copies
# these into the PVC on every boot (config.yaml always; runtime.json only if
# absent so hot-reload API state persists across pod restarts).
COPY defenseclaw-config.yaml /opt/defenseclaw-config/config.yaml
COPY defenseclaw-guardrail-runtime.json /opt/defenseclaw-config/guardrail_runtime.json
# Task #38: full OPA policy tree. Vendored from defenseclaw source repo
# (policies/rego/* + policies/guardrail/strict/*); data.json customized to
# allow our infra hosts (prod-telemetry, log-telemetry, anthropic, teams webhook, bot framework
# auth endpoints). Entrypoint copies this into the PVC at /defenseclaw/.
# defenseclaw/policies/ on every boot. Declarative — policies live in git,
# never edited at runtime.
COPY defenseclaw-policies/ /opt/defenseclaw-policies/
COPY defenseclaw-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/mcp_proxy.py /usr/local/bin/sidecar-identity-derive.py

# Non-root user. HOME=/defenseclaw so ~/.defenseclaw is /defenseclaw/.defenseclaw,
# which is the PVC mount point.
RUN useradd --create-home --home-dir /defenseclaw --uid 10002 --shell /bin/bash dcgw \
 && mkdir -p /defenseclaw/.defenseclaw \
 && chown -R dcgw:dcgw /defenseclaw

USER dcgw
WORKDIR /defenseclaw

# 4000  = guardrail proxy (LLM traffic inspection)
# 18970 = sidecar REST API (Python CLI talks to this)
# 8788  = MCP proxy (only used when MCP_PROXY_ENABLED=true)
EXPOSE 4000 18970 8788

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

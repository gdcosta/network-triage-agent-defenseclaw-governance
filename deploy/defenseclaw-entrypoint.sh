#!/bin/bash
# DefenseClaw sidecar entrypoint.
#
# `defenseclaw-gateway start` daemonizes by design, which doesn't fit the
# k8s "PID 1 = main process" pattern. We start the daemon, tail its log to
# surface stdout for the OTel DaemonSet, and (optionally) launch the MCP
# proxy alongside. SIGTERM is forwarded to all children.
#
# State: ~/.defenseclaw (= /defenseclaw/.defenseclaw) backed by PVC.
#
# Task #29 (v2): pre-compute the sidecar's identity and export it to a shared
# emptyDir at /var/run/sidecar-identity for the openclaw container to consume.
#
# Identity model (verified empirically 2026-05-18):
#   - device.key: Ed25519 PEM private key, persistent on .defenseclaw PVC
#   - .env:       DEFENSECLAW_GATEWAY_TOKEN, persistent on .defenseclaw PVC
#   - deviceId = sha256(Ed25519_public_key_raw_bytes)
#   - publicKey = base64(raw 32-byte Ed25519 public key)
#
# Both files regenerate together on PVC wipe (fresh onboard). The openclaw
# mirror script consumes this and updates its paired.json — removes the
# manual fix-sidecar-pairing.py kubectl-exec step from the loop.
set -euo pipefail

STATE_DIR="$HOME/.defenseclaw"
DEVICE_KEY="$STATE_DIR/device.key"
SHARED_IDENTITY="/var/run/sidecar-identity"

# ---- Task #30: seed config.yaml + guardrail_runtime.json (BEFORE daemon start)
# config.yaml is policy-as-code → ALWAYS overwrite from the image copy. Editing
# guardrail policy means editing the file in git and rebuilding the image.
# guardrail_runtime.json holds hot-reloadable mode state (PATCH-able via the
# sidecar API) → only seed if missing, otherwise preserve runtime changes.
mkdir -p "$STATE_DIR"
if [ -f /opt/defenseclaw-config/config.yaml ]; then
  cp /opt/defenseclaw-config/config.yaml "$STATE_DIR/config.yaml"
  chmod 0644 "$STATE_DIR/config.yaml"
  echo "[entrypoint] wrote $STATE_DIR/config.yaml from image template (task #30)"
  # Per-pod agent identity for audit attribution (event.agent_name / agent_id).
  # The sidecar image + config.yaml are shared by all three workloads, so a
  # baked-in agent.name would be identical everywhere (all "openclaw"). DefenseClaw
  # does NOT bind env -> config, so we append a top-level agent: block here from
  # per-deployment env vars. Unset => block omitted => prior default behaviour.
  # agent.name is read directly by the agent registry and ALWAYS wins over the
  # connector-default fallback (internal/gateway/agent_registry.go).
  if [ -n "${DEFENSECLAW_AGENT_ID:-}" ] || [ -n "${DEFENSECLAW_AGENT_NAME:-}" ]; then
    {
      echo ""
      echo "agent:"
      [ -n "${DEFENSECLAW_AGENT_ID:-}" ]   && echo "  id: ${DEFENSECLAW_AGENT_ID}"
      [ -n "${DEFENSECLAW_AGENT_NAME:-}" ] && echo "  name: ${DEFENSECLAW_AGENT_NAME}"
    } >> "$STATE_DIR/config.yaml"
    echo "[entrypoint] set agent identity id=${DEFENSECLAW_AGENT_ID:-} name=${DEFENSECLAW_AGENT_NAME:-}"
  fi
fi
if [ -f /opt/defenseclaw-config/guardrail_runtime.json ] \
   && [ ! -f "$STATE_DIR/guardrail_runtime.json" ]; then
  cp /opt/defenseclaw-config/guardrail_runtime.json "$STATE_DIR/guardrail_runtime.json"
  chmod 0644 "$STATE_DIR/guardrail_runtime.json"
  echo "[entrypoint] seeded $STATE_DIR/guardrail_runtime.json with initial mode (task #30)"
fi

# Task #38: install OPA policies + guardrail rule pack into PVC.
# Always overwrite from the image (declarative — policies as code, single
# source of truth is git). Daemon looks at policy_dir + guardrail.rule_pack_dir
# in config.yaml; we set those to PVC paths so the layout below is what gets read.
if [ -d /opt/defenseclaw-policies ]; then
  mkdir -p "$STATE_DIR/policies/rego" "$STATE_DIR/policies/guardrail"
  cp -r /opt/defenseclaw-policies/rego/. "$STATE_DIR/policies/rego/"
  cp -r /opt/defenseclaw-policies/guardrail/. "$STATE_DIR/policies/guardrail/"
  # CLI's `defenseclaw-gateway policy show` looks for data.json directly at
  # policy_dir (no /rego/ subdir), while the daemon uses {policy_dir}/rego/.
  # Copy data.json to the parent dir so the CLI works too — daemon path is
  # unaffected. Source: internal/cli/policy.go::resolveRegoDir().
  cp /opt/defenseclaw-policies/rego/data.json "$STATE_DIR/policies/data.json"
  echo "[entrypoint] installed OPA policies + guardrail rule pack to $STATE_DIR/policies/ (task #38)"
fi

# Start the DefenseClaw gateway daemon (idempotent).
defenseclaw-gateway start

# Wait briefly for the gateway log + device.key + .env to settle. On a fresh
# PVC, the daemon writes device.key + .env on first boot; on a warm restart
# they already exist.
for i in $(seq 1 30); do
  [ -f "$STATE_DIR/gateway.log" ] && [ -f "$DEVICE_KEY" ] && [ -f "$STATE_DIR/.env" ] && break
  sleep 1
done

# ---- Task #29 v3: export identity to shared volume ------------------------
# Compute deviceId locally via the Python helper (uses `cryptography` for
# Ed25519 public-key derivation — openssl can't parse defenseclaw's custom
# `-----BEGIN ED25519 PRIVATE KEY-----` PEM label). Helper outputs a JSON
# blob with deviceId + publicKey + token; we atomically rename into place.
if [ -d "$SHARED_IDENTITY" ] && [ -f "$DEVICE_KEY" ] && [ -f "$STATE_DIR/.env" ]; then
  if /opt/mcp-proxy-venv/bin/python3 /usr/local/bin/sidecar-identity-derive.py \
        "$DEVICE_KEY" "$STATE_DIR/.env" \
        > "$SHARED_IDENTITY/identity.json.tmp" 2>/tmp/identity-derive.err; then
    chmod 0644 "$SHARED_IDENTITY/identity.json.tmp"
    mv "$SHARED_IDENTITY/identity.json.tmp" "$SHARED_IDENTITY/identity.json"
    # Echo the deviceId for at-a-glance log verification (matches what the
    # daemon broadcasts in its connect handshake — sha256 of Ed25519 pubkey).
    DEVICE_ID=$(/opt/mcp-proxy-venv/bin/python3 -c \
        'import json,sys; print(json.load(open("'"$SHARED_IDENTITY"'/identity.json"))["deviceId"])')
    echo "[entrypoint] exported sidecar identity to $SHARED_IDENTITY/identity.json (task #29)"
    echo "[entrypoint]   deviceId=${DEVICE_ID:0:16}..."
  else
    echo "[entrypoint] WARN: sidecar-identity-derive.py failed — skipping identity export"
    echo "[entrypoint]   stderr from helper:"
    sed 's/^/[entrypoint]     /' < /tmp/identity-derive.err || true
    rm -f "$SHARED_IDENTITY/identity.json.tmp" /tmp/identity-derive.err
  fi
else
  # Either shared volume not mounted (triage-agent pod has no openclaw peer),
  # or device.key / .env missing (daemon still warming up). Silent no-op.
  :
fi

# ---- Optional MCP proxy (B′-2, task #34) ----------------------------------
# Only enabled on the triage agent's sidecar (kl-openclaw pod leaves
# MCP_PROXY_ENABLED unset). When enabled, the proxy binds the SSE transport
# on $MCP_PROXY_PORT (default 8788) and the agent's mcp-remote connects to
# http://127.0.0.1:8788/sse from the triage-agent container (same pod,
# shared net-ns).
#
# Task #41: also export DEFENSECLAW_GATEWAY_TOKEN env so the proxy can
# authenticate to the local sidecar's /api/v1/inspect/tool endpoint. The
# token already lives on the PVC at $STATE_DIR/.env (auto-generated by
# defenseclaw-gateway on first boot). We could ALSO read it from the
# shared /var/run/sidecar-identity/identity.json — but that file only
# exists in pods that mount the shared emptyDir (kl-openclaw only). The
# PVC-based path works on every pod that has a defenseclaw-sidecar.
MCP_PROXY_PID=
if [ "${MCP_PROXY_ENABLED:-false}" = "true" ]; then
  if [ -f "$STATE_DIR/.env" ]; then
    GW_TOKEN=$(grep '^DEFENSECLAW_GATEWAY_TOKEN=' "$STATE_DIR/.env" \
               | cut -d= -f2- | tr -d '"' | tr -d "'")
    if [ -n "$GW_TOKEN" ]; then
      export DEFENSECLAW_GATEWAY_TOKEN="$GW_TOKEN"
      echo "[entrypoint] exported DEFENSECLAW_GATEWAY_TOKEN for MCP proxy inspect (task #41, ${#GW_TOKEN} chars)"
    else
      echo "[entrypoint] WARN: $STATE_DIR/.env has no DEFENSECLAW_GATEWAY_TOKEN — proxy inspect calls will fail-open"
    fi
  fi

  echo "[entrypoint] starting MCP proxy (B′-2, task #34) on ${MCP_PROXY_HOST:-0.0.0.0}:${MCP_PROXY_PORT:-8788}"
  /opt/mcp-proxy-venv/bin/python3 /usr/local/bin/mcp_proxy.py &
  MCP_PROXY_PID=$!
  echo "[entrypoint] MCP proxy PID=$MCP_PROXY_PID"
fi

# Tail the gateway log in background so we can also watch our own PID.
tail -F "$STATE_DIR/gateway.log" &
TAIL_PID=$!

cleanup() {
  echo "[entrypoint] caught signal — stopping children"
  if [ -n "$MCP_PROXY_PID" ]; then
    kill -TERM "$MCP_PROXY_PID" 2>/dev/null || true
  fi
  defenseclaw-gateway stop 2>&1 || true
  kill -TERM "$TAIL_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  exit 0
}
trap cleanup TERM INT

# Wait for any child to exit. If the proxy crashes we want to know — k8s
# will restart the pod on liveness probe failure (sidecar-api /health).
wait

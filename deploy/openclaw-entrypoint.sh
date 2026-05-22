#!/bin/bash
# OpenClaw container entrypoint.
#
# Responsibilities, in order:
#   1. First-run onboarding if no openclaw.json exists (idempotent)
#   2. Stage the DefenseClaw plugin into ~/.openclaw/extensions/
#   3. Register anthropic / msteams / defenseclaw plugins
#   4. Write channels.msteams + Splunk MCP config from env vars
#   5. exec the gateway in the foreground
#
# Defensive: continue past individual step failures so we always reach
# the gateway start (and produce useful logs) even if a setup step misbehaves.
#
# Required env vars:
#   ANTHROPIC_API_KEY      — for the agent's LLM
#   MSTEAMS_APP_ID         — Bot Framework App ID
#   MSTEAMS_APP_PASSWORD   — Bot Framework client secret
#   MSTEAMS_TENANT_ID      — Azure AD tenant ID

# Strict undefined-var detection, but NOT -e — we want to survive plugin-install
# failures so we get logs. Individual critical steps below check $? explicitly.
set -uo pipefail

echo "[entrypoint] $(date -Iseconds) starting"
echo "[entrypoint] HOME=$HOME PATH=$PATH"
echo "[entrypoint] required env present?"
for v in ANTHROPIC_API_KEY MSTEAMS_APP_ID MSTEAMS_APP_PASSWORD MSTEAMS_TENANT_ID; do
  if [ -n "${!v:-}" ]; then echo "  $v: set"; else echo "  $v: MISSING"; fi
done

STATE_DIR="$HOME/.openclaw"
CONFIG="$STATE_DIR/openclaw.json"

# -- 1. Onboarding + Anthropic auth refresh (task #48) ------------------------
# onboard writes the Anthropic API key into the agent's STORED auth profile
# (~/.openclaw/agents/main/agent/auth-state.json). OpenClaw authenticates LLM
# calls from that STORED profile, NOT from the ANTHROPIC_API_KEY env var — so a
# rotated key (k8s Secret) never reaches the bot unless the profile is re-written.
# Therefore run onboard on EVERY start (not just first run) so the stored profile
# is always re-synced from env. Without this, rotating the key leaves the bot
# 401'ing on the OLD key until someone re-runs onboard by hand (the multi-hour
# trap of 2026-05-21). --skip-health skips the probe against the not-yet-running
# gateway (it would otherwise exit non-zero). onboard overwrites openclaw.json,
# but steps 2-3 below rebuild channels/MCP/plugins, so the final config is
# deterministic regardless. (No env-ref option exists for a provider api-key
# profile on this OpenClaw version, so re-onboard is the mechanism.)
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY is required}"
if [ -f "$CONFIG" ]; then
  echo "[entrypoint] config exists — re-running onboard to refresh stored Anthropic auth from env (task #48)"
else
  echo "[entrypoint] no config at $CONFIG — first-run onboard"
fi
openclaw onboard \
  --skip-daemon --skip-health \
  --non-interactive --accept-risk \
  --auth-choice apiKey \
  --anthropic-api-key "$ANTHROPIC_API_KEY" \
  && echo "[entrypoint] onboard / auth-refresh complete" \
  || echo "[entrypoint] WARN: onboard exited non-zero (continuing; bot may use stale auth)"

# -- 2. Stage the DefenseClaw plugin ------------------------------------------
# Always re-copy: keeps the plugin in sync with the version baked into the image
# across pod restarts. Idempotent — same content, same hash.
mkdir -p "$STATE_DIR/extensions/defenseclaw"
cp -R /opt/defenseclaw-plugin/. "$STATE_DIR/extensions/defenseclaw/"
echo "[entrypoint] DefenseClaw plugin staged"

# -- 2a. Stage SOUL.md (bot system prompt) ------------------------------------
# OpenClaw auto-injects a *workspace bootstrap file* named SOUL.md into the
# agent's system prompt (contextInjection defaults to "always", bootstrapMaxChars
# 12000). VERIFIED against `openclaw config schema` 2026.5.7: the recognized
# bootstrap files are SOUL.md / USER.md / HEARTBEAT.md / IDENTITY.md, read from
# the agent workspace root (agents.defaults.workspace). So our prompt MUST land
# at <workspace>/SOUL.md.
#
# (Earlier this copied to agents/main/claw.md — a wrong guess that was never
# loaded, leaving the bot on OpenClaw's default generic-assistant persona, which
# happily answered out-of-scope requests. That's the bug this fixes.)
#
# Always overwrite so ConfigMap edits propagate on restart. onboard (step 1)
# creates the workspace + a default template SOUL.md; we replace it with ours.
if [ -n "${SOUL_PATH:-}" ] && [ -f "$SOUL_PATH" ]; then
  WORKSPACE=$(python3 -c "import json,os; print(json.load(open(os.path.join(os.environ['HOME'],'.openclaw','openclaw.json')))['agents']['defaults'].get('workspace',''))" 2>/dev/null)
  [ -z "$WORKSPACE" ] && WORKSPACE="$STATE_DIR/workspace"
  mkdir -p "$WORKSPACE"
  cp "$SOUL_PATH" "$WORKSPACE/SOUL.md"
  SOUL_BYTES=$(wc -c < "$WORKSPACE/SOUL.md")
  echo "[entrypoint] SOUL.md installed at $WORKSPACE/SOUL.md ($SOUL_BYTES bytes) — injected as system prompt"
  # Remove the stale wrong-path copy a previous image may have left on the PVC.
  rm -f "$STATE_DIR/agents/main/claw.md" 2>/dev/null || true
else
  echo "[entrypoint] SOUL_PATH not set or file missing — bot will use OpenClaw default assistant prompt"
fi

# -- 2b. Register the three plugins we need --------------------------------
# onboard doesn't auto-enable provider/channel/extension plugins. The local
# install did this via separate `openclaw plugins install ...` and
# `defenseclaw setup guardrail` commands. In the container we do it here.
echo "[entrypoint] === plugin registration ==="

# Verify the msteams npm-install actually landed at the expected path
echo "[entrypoint] checking msteams plugin path"
if [ -d /usr/local/lib/node_modules/@openclaw/msteams ]; then
  echo "  found at /usr/local/lib/node_modules/@openclaw/msteams"
else
  echo "  NOT at /usr/local/lib/node_modules/@openclaw/msteams — searching:"
  find / -maxdepth 6 -type d -name msteams 2>/dev/null | head -5 || true
fi

# (anthropic enable happens AFTER plugin installs below — `openclaw plugins
# install` rewrites openclaw.json on each call and would clobber our edit
# if we did it here.)

# msteams plugin
echo "[entrypoint] installing msteams plugin"
openclaw plugins install /usr/local/lib/node_modules/@openclaw/msteams --force 2>&1 \
  | sed 's/^/  msteams: /' || echo "[entrypoint] WARN: msteams install exited non-zero (continuing)"

# defenseclaw plugin — needs --dangerously-force-unsafe-install because the
# DefenseClaw enforcer module uses `child_process` (a CodeGuard danger pattern,
# but legitimate here: that's exactly how it inspects subprocess executions).
echo "[entrypoint] installing defenseclaw plugin (with unsafe-install bypass for child_process)"
openclaw plugins install "$STATE_DIR/extensions/defenseclaw" --force --dangerously-force-unsafe-install 2>&1 \
  | sed 's/^/  defenseclaw: /' || echo "[entrypoint] WARN: defenseclaw install exited non-zero (continuing)"

echo "[entrypoint] plugin registration done — current plugins:"
openclaw plugins list 2>&1 | head -20 | sed 's/^/  /' || true

# -- 3. Wire channels.msteams + Splunk MCP + enable anthropic ---------------
# Single Python block that runs AFTER the plugin installs, so its writes
# are the LAST edits to openclaw.json before the gateway starts.
python3 - <<'PYEOF'
import json, os, shlex, sys
from pathlib import Path

cfg_path = Path(os.environ['HOME']) / '.openclaw' / 'openclaw.json'
cfg = json.loads(cfg_path.read_text())

# Pin workspace-bootstrap injection to "always" so the bot's SOUL.md (its scope
# guardrail — staged at <workspace>/SOUL.md in step 2a) is ALWAYS injected into
# the system prompt. This is OpenClaw's default, but pinning it means a future
# default change can't silently turn the bot back into a generic assistant.
cfg.setdefault('agents', {}).setdefault('defaults', {})['contextInjection'] = 'always'
print("[entrypoint] agents.defaults.contextInjection = always (SOUL.md scope guardrail pinned)")

# Pin the chat model to Sonnet (cost: Opus is overkill + priciest for triage
# Q&A). Set every start so it survives the re-onboard in step 1 (which would
# otherwise leave whatever default onboard picked, historically Opus).
cfg.setdefault('agents', {}).setdefault('defaults', {}).setdefault('model', {})['primary'] = 'anthropic/claude-sonnet-4-6'
print("[entrypoint] agents.defaults.model.primary = anthropic/claude-sonnet-4-6 (cost: Opus->Sonnet)")

# Enable the anthropic provider plugin — it's bundled with openclaw but only
# auto-loads when explicitly listed in plugins.entries.
cfg.setdefault('plugins', {}).setdefault('entries', {})['anthropic'] = {'enabled': True}
print("[entrypoint] anthropic provider enabled in plugins.entries")

# Task #30: explicitly allow-list every plugin we depend on. Without this,
# openclaw warns "plugins.allow is empty" and only auto-loads bundled
# plugins — defenseclaw (custom extension at .openclaw/extensions/defenseclaw)
# is silently NOT loaded, so its fetch interceptor never registers in the
# gateway process and tool inspection counters stay at zero. Adding
# `plugins.allow` mirrors what the Mac install does (see project memory).
cfg.setdefault('plugins', {})['allow'] = ['anthropic', 'defenseclaw', 'msteams']
cfg.setdefault('plugins', {}).setdefault('load', {})['paths'] = [
    '/openclaw/.openclaw/extensions/defenseclaw',
]
print("[entrypoint] plugins.allow = ['anthropic','defenseclaw','msteams']; plugins.load.paths set")

# Microsoft Teams channel — credentials + the dmPolicy/allowFrom auth-layer
# settings we learned about the hard way during local validation (see memory
# project_openclaw_msteams_local_complete).
ms_required = ['MSTEAMS_APP_ID', 'MSTEAMS_APP_PASSWORD', 'MSTEAMS_TENANT_ID']
missing = [k for k in ms_required if not os.environ.get(k)]
if missing:
    print(f"[entrypoint] WARNING: msteams env not set: {missing} — channel will not function", file=sys.stderr)
else:
    cfg.setdefault('channels', {})['msteams'] = {
        'enabled': True,
        'appId': os.environ['MSTEAMS_APP_ID'],
        'appPassword': os.environ['MSTEAMS_APP_PASSWORD'],
        'tenantId': os.environ['MSTEAMS_TENANT_ID'],
        # NOTE: schema only accepts {port, path} here — no `host` key is valid.
        # msteams provider binds 127.0.0.1 by default, so external Service traffic
        # to :3978 won't reach it. Pending fix: either find a different config knob
        # (gateway-level or channel-level), or add a socat bridge in the pod.
        'webhook': {'port': 3978, 'path': '/api/messages'},
        'dmPolicy': os.environ.get('MSTEAMS_DM_POLICY', 'open'),
        'allowFrom': [s.strip() for s in os.environ.get('MSTEAMS_ALLOW_FROM', '*').split(',')],
    }
    print("[entrypoint] channels.msteams configured")

# Always remove any stale top-level `mcpServers` key — an earlier version
# of this entrypoint wrote that (wrong) key and it persists on the PVC
# across image updates. OpenClaw's schema rejects it.
if cfg.pop('mcpServers', None) is not None:
    print("[entrypoint] removed stale legacy `mcpServers` top-level key")

# Splunk MCP server — optional; only register if env vars present.
# Correct config key is `mcp.servers.<name>` (nested), verified against
# a working local install.
if os.environ.get('SPLUNK_MCP_COMMAND'):
    cfg.setdefault('mcp', {}).setdefault('servers', {})['splunk-triage'] = {
        'command': os.environ['SPLUNK_MCP_COMMAND'],
        'args': shlex.split(os.environ.get('SPLUNK_MCP_ARGS', '')),
        'env': {'NODE_TLS_REJECT_UNAUTHORIZED': '0'},
    }
    print("[entrypoint] splunk-triage MCP registered at mcp.servers.splunk-triage")

# Triage MCP server — gives the bot structured access to the triage agent's
# state (active alerts, recent reports, history). Connects to the HTTP/SSE
# MCP server running in the net-triage-agent namespace. Bridged via
# `mcp-remote` (the same Node stdio<->HTTP bridge used for Splunk MCP).
# Set TRIAGE_MCP_URL=disabled to opt out (e.g., for local testing).
TRIAGE_MCP_URL = os.environ.get(
    'TRIAGE_MCP_URL',
    'http://triage-mcp.net-triage-agent.svc.cluster.local:8081/sse',
)
if TRIAGE_MCP_URL and TRIAGE_MCP_URL != 'disabled':
    cfg.setdefault('mcp', {}).setdefault('servers', {})['triage'] = {
        'command': 'npx',
        # Pin mcp-remote — bare 'mcp-remote' lets npx pull latest, which drifted
        # to a version that breaks the SSE handshake with triage-mcp's FastMCP
        # (mcp==1.27.1) server -> "Request validation failed". 0.1.37 matches the
        # version splunk-triage uses. See task #42.
        'args': ['-y', 'mcp-remote@0.1.37', TRIAGE_MCP_URL, '--allow-http'],
        # No NODE_TLS_REJECT_UNAUTHORIZED needed — plain HTTP within the
        # cluster, encrypted at the network layer by Cilium WireGuard.
    }
    print(f"[entrypoint] triage MCP registered at mcp.servers.triage -> {TRIAGE_MCP_URL}")

cfg_path.write_text(json.dumps(cfg, indent=2) + "\n")
PYEOF

# -- 3a. Mirror the sidecar's auto-generated gateway token (task #29) -------
# Waits for the sidecar to export its identity to /var/run/sidecar-identity
# (via the shared emptyDir mounted in both containers), then updates this
# container's paired.json with the matching token. Idempotent — no-op if
# already current. Replaces the manual fix-sidecar-pairing.py kubectl-exec
# step that used to be required after every PVC wipe.
#
# Up to 60s wait for the sidecar to come online. If we time out, the mirror
# script logs a WARN and the openclaw daemon starts anyway (degraded
# governance, but not blocked) — matches the pre-#29 fail-open posture.
echo "[entrypoint] === task #29: sidecar token mirror ==="
SHARED_IDENTITY="/var/run/sidecar-identity"
# v3 of the sidecar identity export writes a single identity.json; older
# variants wrote paired.json + .env. Wait for whichever exists.
if [ -d "$SHARED_IDENTITY" ]; then
  for i in $(seq 1 60); do
    if [ -f "$SHARED_IDENTITY/identity.json" ] \
       || { [ -f "$SHARED_IDENTITY/paired.json" ] && [ -f "$SHARED_IDENTITY/.env" ]; }; then
      break
    fi
    sleep 1
  done
  python3 /usr/local/bin/sidecar-token-mirror.py \
    || echo "[entrypoint] WARN: sidecar-token-mirror exited non-zero (continuing)"
else
  echo "[entrypoint] WARN: $SHARED_IDENTITY not mounted — skipping token mirror"
fi

# -- 3b. Export OPENCLAW_GATEWAY_TOKEN for the DefenseClaw plugin (task #30) -
# The DefenseClaw OpenClaw plugin (loaded at openclaw startup) patches
# globalThis.fetch / https.request to redirect LLM API calls through the
# guardrail proxy at 127.0.0.1:4000. To authenticate to the proxy, it reads
# `process.env.OPENCLAW_GATEWAY_TOKEN` (default; see
# dist/sidecar-config.js DEFAULT_TOKEN_ENV).
#
# The token itself is generated by defenseclaw-gateway on first boot and
# lives at /defenseclaw/.defenseclaw/.env on the sidecar's PVC. We can't
# read that directly from this container (different PVC), but task #29
# already exports it as part of identity.json on the shared emptyDir.
# Read + export here so `exec openclaw` inherits it.
if [ -f "$SHARED_IDENTITY/identity.json" ]; then
  GUARDRAIL_TOKEN=$(python3 -c \
    'import json,sys; print(json.load(open("/var/run/sidecar-identity/identity.json")).get("token",""))' \
    2>/dev/null || echo "")
  if [ -n "$GUARDRAIL_TOKEN" ]; then
    export OPENCLAW_GATEWAY_TOKEN="$GUARDRAIL_TOKEN"
    echo "[entrypoint] exported OPENCLAW_GATEWAY_TOKEN for DefenseClaw plugin (task #30, ${#GUARDRAIL_TOKEN} chars)"
  else
    echo "[entrypoint] WARN: identity.json present but no token field — DefenseClaw plugin will not authenticate"
  fi
else
  echo "[entrypoint] WARN: $SHARED_IDENTITY/identity.json missing — DefenseClaw plugin will not authenticate (counters will stay at 0)"
fi

# -- 4. Run the gateway in foreground (PID 1 = node) -------------------------
echo "[entrypoint] starting OpenClaw gateway (foreground)"
exec openclaw gateway run

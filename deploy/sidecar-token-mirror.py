#!/usr/bin/env python3
"""
sidecar-token-mirror.py — task #29 automation (v2: identity.json format).

In-pod equivalent of fix-sidecar-pairing.py. Runs from the openclaw container's
entrypoint on every pod start, BEFORE the openclaw daemon launches, so the
daemon reads paired.json with the sidecar's current token already in place.

Reads the sidecar's exported identity from /var/run/sidecar-identity/identity.json
(populated by sidecar entrypoint — a JSON blob with deviceId + publicKey + token,
computed from device.key + .env on the sidecar's PVC). Updates the openclaw
container's own paired.json at /openclaw/.openclaw/devices/paired.json idempotently.

Replaces the manual `kubectl exec` script that had to be re-run after every
PVC wipe or fresh onboard.

v2 redesign (2026-05-18): v1 incorrectly assumed `/defenseclaw/.openclaw/devices/paired.json`
existed in the sidecar container — turns out that path is never created by
`defenseclaw-gateway start` alone (only by `defenseclaw setup guardrail` which
isn't part of our pod lifecycle). The actual persistent identity state on the
sidecar's PVC is `device.key` (Ed25519 PEM private key, 115 bytes) + `.env`
(DEFENSECLAW_GATEWAY_TOKEN). Verified empirically:
  deviceId = sha256(Ed25519_public_key_raw)  ← derives from device.key
  token    = DEFENSECLAW_GATEWAY_TOKEN       ← from .env

Pure stdlib — no cryptography package needed because the sidecar entrypoint
does the openssl crypto and pre-computes everything into identity.json.
"""
from __future__ import annotations

import json
import os
import sys
import time

IDENTITY_PATH = os.environ.get("SIDECAR_IDENTITY_PATH", "/var/run/sidecar-identity/identity.json")
OC_PAIRED = os.environ.get("OC_PAIRED_PATH", "/openclaw/.openclaw/devices/paired.json")

DEFAULT_SCOPES = [
    "operator.read",
    "operator.write",
    "operator.admin",
    "operator.approvals",
]


def _log(msg: str) -> None:
    sys.stdout.write(f"[mirror] {msg}\n")
    sys.stdout.flush()


def build_entry(device_id: str, public_key: str, token: str, now_ms: int) -> dict:
    """Construct a new openclaw-side paired.json entry for the sidecar device."""
    return {
        "deviceId": device_id,
        "publicKey": public_key,
        "platform": "linux",
        "clientId": "gateway-client",
        "clientMode": "backend",
        "displayName": "defenseclaw-sidecar",
        "role": "operator",
        "roles": ["operator"],
        "scopes": DEFAULT_SCOPES,
        "approvedScopes": DEFAULT_SCOPES,
        "tokens": {
            "operator": {
                "token": token,
                "role": "operator",
                "scopes": DEFAULT_SCOPES,
                "createdAtMs": now_ms,
            },
        },
        "createdAtMs": now_ms,
        "approvedAtMs": now_ms,
    }


def merge_entry(existing: dict, token: str, now_ms: int) -> bool:
    """Update the operator token on an existing entry. Returns True if anything
    changed, False if already current. Other openclaw-managed state is preserved."""
    scopes = existing.get("scopes") or DEFAULT_SCOPES
    existing.setdefault("tokens", {})
    current_op = existing["tokens"].get("operator") or {}
    if current_op.get("token") == token:
        return False
    existing["tokens"]["operator"] = {
        "token": token,
        "role": "operator",
        "scopes": scopes,
        "createdAtMs": now_ms,
    }
    return True


def main() -> int:
    # If sidecar hasn't exported its identity yet, exit cleanly — openclaw
    # should still start (degraded governance, but not blocked). WARN goes
    # to stdout so log-telemetry picks it up.
    if not os.path.exists(IDENTITY_PATH):
        _log(
            f"WARN: sidecar identity not yet exported to {IDENTITY_PATH} — "
            "skipping mirror (governance link may need manual fix until next pod restart)"
        )
        return 0

    try:
        with open(IDENTITY_PATH) as f:
            identity = json.load(f)
        device_id = identity["deviceId"]
        public_key = identity["publicKey"]
        token = identity["token"]
    except Exception as e:
        _log(f"ERROR parsing sidecar identity: {type(e).__name__}: {e}")
        return 1

    _log(f"sidecar deviceId={device_id[:16]}... token={token[:8]}...")

    os.makedirs(os.path.dirname(OC_PAIRED), exist_ok=True)
    if os.path.exists(OC_PAIRED):
        oc = json.loads(open(OC_PAIRED).read())
    else:
        oc = {}

    now_ms = int(time.time() * 1000)

    if device_id in oc:
        changed = merge_entry(oc[device_id], token, now_ms)
        if not changed:
            _log("no change needed — paired.json already current")
            return 0
        _log("updated existing entry's operator token")
    else:
        oc[device_id] = build_entry(device_id, public_key, token, now_ms)
        _log("added new sidecar entry")

    # Atomic write — write to .tmp, fsync, rename. Avoids leaving openclaw
    # with a half-written paired.json if we're interrupted mid-write.
    tmp = OC_PAIRED + ".tmp"
    with open(tmp, "w") as f:
        json.dump(oc, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, OC_PAIRED)
    _log(f"wrote {OC_PAIRED} ({len(oc)} device(s) total)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

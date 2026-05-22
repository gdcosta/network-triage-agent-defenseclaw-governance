# Tiny socat bridge for the msteams 127.0.0.1 binding in the kl-openclaw pod.
#
# OpenClaw's msteams provider binds 127.0.0.1:3978 only and the channel
# schema has no host override (verified via `openclaw config schema` — the
# webhook block accepts {port, path} with additionalProperties: false). This
# image runs socat as PID 1 so a sidecar in the kl-openclaw pod can listen
# on the pod IP and forward connections to openclaw's loopback msteams port,
# letting the kube Service route Bot Framework webhooks to it.
#
# See the `msteams-bridge` container in k8s/deployment.yaml for the
# listen+forward args.
#
# Why debian-bookworm-slim and not alpine: log-telemetry's egress is locked down —
# Docker Hub works but Alpine's CDN (dl-cdn.alpinelinux.org) returns
# Permission Denied. Debian's apt mirrors are reachable (same base as
# defenseclaw.Dockerfile, so we know it works).
#
# Build + push (on log-telemetry, same flow as the other kl-* images):
#   cd ~/kl-governance
#   docker build -t localhost:5000/kl-msteams-bridge:latest -f socat.Dockerfile .
#   docker push localhost:5000/kl-msteams-bridge:latest
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends socat \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Non-root for defense in depth — socat doesn't need root to bind :8978.
RUN useradd --uid 10003 --shell /usr/sbin/nologin bridge
USER bridge

ENTRYPOINT ["socat"]

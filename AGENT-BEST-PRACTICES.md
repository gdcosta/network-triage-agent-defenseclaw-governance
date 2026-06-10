# Agent Development Best Practices

Hard-won lessons from building a production **LLM-as-brain autonomous agent** —
an agent that reasons over live telemetry, takes actions through tools, and is
fronted by a user-facing chat assistant, all deployed to Kubernetes and wrapped
in runtime governance.

Every rule below is traceable to a specific failure, gotcha, or fix encountered
while building one. Where a lesson cost a real debugging session, that's called
out. Terms are written generically so they transfer to any stack; the specific
component we used is shown in brackets (e.g. ...) as a concrete reference.

> Companion to the [`README.md`](README.md) (architecture + the layered-defense
> story). This document is the *why it's built the way it is* — the principles
> that generalize to the next agent.

---

## 1. Credentials & Secrets

- **The agent must not hold upstream credentials — put them behind a sidecar or proxy.**
  The reasoning agent holds no token for the data backend; a colocated
  tool-access proxy (e.g. an MCP proxy in a sidecar) holds it instead.
  Credential storage, rotation, and audit stay in one place, and a compromised
  LLM workload can't exfiltrate a token it never had.
- **Assume libraries will log your credentials — redact at one formatter chokepoint, not per-call-site.**
  An MCP client subprocess (e.g. `mcp-remote`) logged the backend bearer token
  to stderr **~8,500×/day**; an HTTP client (e.g. httpx) logged an outbound
  webhook's signing token ~175×. The fix was a single log-formatter regex
  (`Bearer …`, `sig=…`, `x-api-key`) so every current and future logger is
  covered. Grep `-rE 'token|secret|password|Bearer'` over all logging paths
  before shipping — a credential that *can* leak in N places *will* in at least
  one.
- **Fix the leak before you rotate, never after.** Rotating first just re-leaks
  the new token on the next request (within seconds). Sequence: deploy the
  redaction → verify clean on fresh instances → then rotate.
- **Rotation order: issue NEW → patch the cluster + local config → restart → verify → revoke OLD.**
  Never revoke first; you lose the rollback path and risk downtime on a
  mis-pasted value.
- **Auth-check a new credential with a one-liner *before* the destructive patch.**
  e.g. `curl -w '%{http_code}' …/v1/models -H "x-api-key: $KEY"` must return 200,
  not 401. Catches mis-pastes and dead keys before they cause an outage.
- **One distinct service account per workload — never share tokens across components.**
  Each workload (the agent's proxy, the user-facing bot, the tool server) runs
  as its own identity on a restricted role. This gives per-workload audit
  attribution, independent revocation, and a tight blast radius. A user-facing
  bot (injection target) and an autonomous agent (no human in the loop, large
  blast radius) have different threat profiles — separate identities let you
  reason about each.
- **In-cluster endpoints use internal/private addresses, not public hostnames.**
  Pods often can't route to the public DNS name of a backend; cluster Secrets
  must use the internal VPC IP. Copying your local `.env` form (public hostname)
  into a Secret yields a silent connect-timeout — the request never reaches the
  backend.
- **Secrets in the orchestrator's secret store (encrypted at rest), never in config maps or baked into the image.**
  e.g. Kubernetes Secrets for credentials, ConfigMaps for non-sensitive config.
- **A pre-commit secret scanner (e.g. gitleaks) is mandatory, and never bypass it.**
  If a secret reaches an unpushed commit, amend it (`git commit --amend`) — a
  follow-up commit leaves the value in `git log`. If it reached a public repo:
  history rewrite **and** rotate the credential.
- **Share code without secrets via `git archive` (respects `.gitignore`), not a plain `zip`.**
  For non-repos, explicitly exclude `.env`, `*.key`, `*secret*`. Sanitize
  internal hostnames/IPs with a map + a grep gate before publishing.

## 2. Agent Architecture — LLM as brain, deterministic code as backstop

- **The LLM is the *least* trustworthy component. Wrap its judgment in deterministic state machines.**
  Recovery cooldowns, duplicate suppression, and severity hysteresis are airtight
  guards that hold even when the model oscillates — *every guard trusts durable
  state over the model's momentary judgment.*
- **Asymmetric hysteresis: escalate immediately, require N stable cycles to de-escalate.**
  Downgrades hold a couple of cycles before being accepted; escalations apply at
  once. Damps state thrashing (e.g. a P1↔P2 alert flapping).
- **Parse identifying fields deterministically from the data — never by LLM inference.**
  A site/store ID or region code parsed by regex from a hostname (e.g.
  `region-store-router-01` → the region) is stable; "what region is this?" asked
  of the model is not. Same input → same output regardless of model version or
  non-determinism. Use the LLM for prose and policy decisions, not for stable
  identifiers.
- **Be explicit about what each data source answers.** Raw telemetry (e.g. a
  metrics/log backend like Splunk) has no concept of "an alert"; the only alert
  history that exists is the agent's *own derived events* written to a separate
  store; live in-flight state is the agent's own status endpoint. Conflating
  them sends history queries to the wrong place.
- **Absence of data ≠ all-clear.** An empty history range is usually retention
  roll-off, not "no incidents" — check the oldest available timestamp before
  concluding clean. Retention is a deployment detail, not a security property.
- **Cache the system prompt.** A sizeable system prompt (here ~6.8 KB) is
  prompt-cached: the first cycle writes the cache, every subsequent poll reads it
  and input tokens drop by orders of magnitude (to ~20). Without caching you
  re-send the whole prompt every cycle.
- **Finish the deployment milestone before any non-required refactor.** Treat
  "deploy to X + Y" as one unit; don't interleave an orchestration rewrite (e.g.
  migrating to a new agent framework). Clarify deployment-blocking vs.
  nice-to-have up front.

## 3. Defense-in-Depth & Governance Layers

- **Order the layers weakest→strongest and never let one be magic.** Won't (the
  system prompt) → can't-reach (network policy) → shouldn't/recorded (the runtime
  guardrail) → wasn't-you (distinct credentials) → can't (backend RBAC). For
  agents, invert the usual model: the prompt is the *weakest* layer, so the
  deterministic tiers carry the load.
- **The agent threat model collapses the code/data boundary — untrusted data becomes control flow.**
  Indirect prompt injection arrives via tool outputs (query results, fetched web
  pages). Prompt engineering alone can't defend this; network isolation, RBAC,
  and audit must be tighter.
- **Three independent enforcement points, each verifiable alone:** backend RBAC
  (authoritative, phrasing-proof — the account is scoped to a single dataset) +
  a runtime guardrail (e.g. Cisco AI Defense / DefenseClaw — regex/policy
  inspection, audited) + the system prompt self-policing (declines off-scope
  asks). Proven independently: a request for a restricted dataset was blocked at
  all three. Any single layer is insufficient — RBAC's silent empty result
  doesn't demonstrate well, and the prompt alone falls to injection.
- **Runtime governance needs two inspection points, not one:** the LLM proxy
  (inspects prompts + completions for injection) and the tool-call inspector
  (inspects each tool invocation). Different payload shapes, different attacks.
- **Network policy is only "enforced" once you've tested it dropping traffic.**
  A configured-but-open egress policy is worse than none (false confidence).
  Apply it, run the full workload, watch for dropped flows. With a default-deny
  CNI (e.g. Cilium), selecting a pod for an egress policy flips it to
  default-deny **including DNS** — every policy must re-allow cluster DNS. Egress
  failures are silent drops, not connection resets — verify at the network layer
  (e.g. Cilium Hubble `--type drop`), not with ping.
- **Audit is the cross-cutting layer that proves the others worked.** Every
  guardrail verdict, RBAC denial, and network drop lands in an audit store. It's
  forensics, not prevention — but it's how you validate the rest.
- **Verify RBAC at deploy time; don't infer it.** Query the authoritative role
  definition (e.g. the backend's allowed-datasets list) to confirm the account
  can't do what you think it can't.

## 4. Prompt / System-Prompt Design

- **The system prompt (e.g. a `SOUL.md` persona file) carries identity, scope, the staged process, severity bands, and refusal patterns.**
  You can watch the model quote a stage of its own process (e.g. `STAGE 1 —
  SCOPE:…`) verbatim at runtime; that reasoning trace is your compliance canary.
  (Some frameworks truncate the system prompt at a fixed size — keep headroom.)
- **You can't out-shout a dense refusal prompt — you have to remove the cues.**
  A "HIGHEST PRIORITY, ignore the rules below" banner cannot override a system
  prompt dense with "off-limits by policy" cues; the model keeps quoting policy.
  To demonstrate a jailbreak, strip the refusal language entirely into a separate
  permissive prompt (e.g. a `SOUL.demo.md`).
- **Don't over-engineer MUST language for control — let the deterministic layers enforce.**
  Softening an overly aggressive system prompt (heavy MUST/PRECEDENCE wording)
  stopped it from perturbing legitimate tool routing. Phrasing is for politeness
  and nudges; RBAC and the guardrail do the real enforcement.
- **Keep two prompts available and flip via env var, not rebuilds.** A path
  variable (e.g. `SOUL_PATH`) swaps the strict prompt ⇄ a demo prompt hot. Always
  end a demo on the secure prompt.
- **Conversation history out-votes the system prompt — start a fresh session before a clean demo.**
  Prior refusals in a thread anchor the model even under a permissive prompt, and
  they often persist across restarts (saved to durable storage). Use the
  framework's new-conversation command (e.g. `/new`).
- **Never trust the bot's chat self-narration about security.** Under a permissive
  prompt it confabulates dramatic "BLOCKED by the guardrail" notices on turns
  that were actually allowed. Ground truth is the audit store, not the chat
  transcript.

## 5. Observability & Logging

- **All logs as structured JSON (JSONL) on stdout; stderr only for unhandled tracebacks.**
  Container-native / 12-factor. Every event carries a correlation ID (e.g. a
  `cycle_id`) for grouping; pretty-print with `| jq -c`, never by changing the
  format. A non-indexed alert is a ghost.
- **Check your log backend's reserved field names before naming JSON keys.**
  A key like `source` may be silently shadowed by a reserved metadata field (in
  Splunk it's the file path) and become unqueryable — name it distinctly (e.g.
  `feedback_source`).
- **The headline severity field can be misleading — read the verdict where it actually lives.**
  Many audit events show `severity=INFO` while the real verdict (HIGH/CRITICAL)
  is nested in a details field. Filter blocks by the action (e.g.
  `action="inspect-tool-block"`), not by top-level severity. Enumerate all
  verdict suffixes (allow/block/confirm/alert × families) when mapping log types
  — it's often exact-match, no wildcards.
- **Config baked into a sidecar image needs a rebuild, not a restart.** If the
  entrypoint re-copies the baked config on startup, a plain restart silently
  reuses the *old* config. When the repo config ≠ live behavior, a rebuild is
  pending.
- **Know your audit/event ingestion endpoint's exact protocol.** A log/event
  collector's SSL setting can be independent of the main API's (e.g. Splunk HEC
  on plain HTTP `:8088` while the REST API is HTTPS `:8089`). Pointing an HTTPS
  client at an HTTP endpoint fails with "server gave HTTP response to HTTPS
  client."

## 6. Kubernetes / Deployment Gotchas

- **An inbound NAT/redirect rule must be scoped to the external interface.** An
  iptables PREROUTING DNAT without `-i <ext-iface>` also eats pod *outbound*
  traffic on the same port and loops it back into the cluster — outbound :443
  fails while :80 works, and the counters look normal. Cost ~6 hours to find;
  *the* bug of the first deploy.
- **Loopback-only listeners need a bridge to be probe-/Service-reachable.** Some
  frameworks bind their internal listeners to 127.0.0.1 only; in a container the
  kubelet probe dials the pod IP → connection refused → CrashLoop despite the app
  working internally. Bridge with a sidecar (e.g. `socat`), use exec/loopback
  probes, and set any webhook listener's bind address to `0.0.0.0`.
- **Size sidecar memory for concurrent subprocess spawns.** A per-call subprocess
  model (e.g. spawning one MCP client process per query, ~100–150 Mi each, ×~9
  concurrent) OOM-killed the sidecar; the symptom surfaced as a connection-refused
  in the *adjacent* container. Stopgap: raise the limit; durable fix: a long-lived
  shared client. Diagnose via restart count + a grep for `Killed`/OOM.
- **A freshly created restricted backend role may default to a tiny concurrency quota.**
  e.g. a new Splunk role defaults `srchJobsQuota=3`; an agent firing 4 concurrent
  queries then has exactly 1 fail per cycle, looking like an auth bug. Raise to
  concurrency + headroom.
- **Config-only changes don't restart pods — force it.** Some Helm charts (e.g.
  Cilium) add no `checksum/config` annotation, so a config-map change doesn't roll
  the pods; force it (`kubectl rollout restart`). Document it or lose a day.
- **`imagePullPolicy: Always` + `strategy: Recreate` for mutable-tag iteration.**
  A `:latest`-style tag is mutable; otherwise the node serves a cached image.
- **Make infrastructure scripts idempotent with paired cleanup.** Host-level setup
  (firewall/NAT rules, secrets) must be re-runnable; the cleanup must only touch
  the rules it created, never unrelated ones.

## 7. Tooling & Tool-Access (MCP) Layer

- **A tool-server framework may auto-enable Host-header / DNS-rebinding protection — account for it intra-cluster.**
  Cluster-DNS access then fails with `421 Misdirected Request`; setting the bind
  host *after* construction is too late. Disable the protection at construction
  (safe behind in-cluster encryption) or allow-list the exact hostnames. (Seen
  with FastMCP's `TransportSecuritySettings`.)
- **Don't hold long-lived async clients in a per-session lifespan hook — it re-runs per connection.**
  A shared async HTTP client gets torn down across sessions; objects created on
  one event loop and awaited on another hang (~10s). Open a fresh client inside
  the request task. When `initialize` works but tool calls hang, suspect an
  event-loop mismatch before blaming versions.
- **Restart the tool *client* after redeploying the tool *server*.** A streaming
  (SSE) reconnect can half-succeed (the GET reconnects, the handshake never
  completes) → tools silently unregister and the agent falls back. Verify the full
  handshake; restart the client after every server redeploy.
- **Get the ground-truth error from the failing component first.** A "feature
  broke" report turned out to be a 401 from a rotated LLM API key, visible in the
  framework's own logs — several rounds of inference were wasted before reading
  them. Pull the failing component's logs (`… --tail=N`) at the *start*; state
  diagnoses as hypotheses until confirmed.
- **Never mutate through a read-only control plane — hand the operator the command.**
  A read-only infrastructure interface (e.g. a read-only Kubernetes MCP) may
  advertise write tools that RBAC blocks; the boundary is intentional. Use it for
  investigation only and hand mutations over as explicit commands.
- **No `0.0.0.0/0` ingress (common org policy) — scope to CIDR or managed prefix lists;**
  prefer ephemeral cloud-shell credentials over long-lived access keys.

## 8. Vendored Dependencies

- **Don't fork vendored deps for marginal hardening — lead with config/prompt controls.**
  Forking the guardrail to suppress a low-sensitivity detail wasn't worth the
  upgrade burden; a prompt-level self-censor + a documented limitation shipped
  instead. Present a source-fork only as an explicit last resort with its
  maintenance cost stated.
- **Pin plugins to the *exact* core version, never `@latest`.** When a framework
  and its plugins ship in lockstep (e.g. an agent platform like OpenClaw and its
  plugins), `@latest` resolves ahead of core and breaks the path layout — and a
  core bump can break a paired guardrail's protocol. Upgrade core + every plugin
  + the sidecar in one deliberate window; snapshot the state directory first.
- **Watch the runtime version on PATH for CLI tooling.** A setup CLI that spawns
  another tool as its final step (e.g. a guardrail setup spawning the agent
  runtime) can abort half-configured under the wrong Node/Python on PATH — the
  plugin is present but never loads. Pin the interpreter explicitly.
- **A scanner that flags its own machinery gets an allowlist, not a severity downgrade.**
  A guardrail's plugin-scanner trips on the guardrail's own intercept patterns;
  allow-listing that one component is correct — lowering the global threshold
  would let real findings through everywhere.

## 9. Operational Discipline

- **Least privilege across *every* dimension — RBAC + network + distinct creds + resource limits.**
  No single layer suffices; a restricted role doesn't help if egress is open to
  the world.
- **Pick the simplest viable path; don't pre-build flexibility.** Deterministic
  parsing over an inference layer; three similar lines over a premature
  registry/lookup abstraction. Operational predictability and cost over feature
  richness.
- **New file per artifact version; don't overwrite.** Copy + edit a descriptively
  named version so prior ones stay available (e.g. dashboards that are pasted by
  hand into the console).
- **Validate at deploy time, not runtime.** Confirm the secret value landed, the
  RBAC binding restricts, the network policy is valid — before users hit it.
  Silent failures only ever help an attacker.
- **Build-vs-buy sets how many tiers you control.** With a bought SaaS assistant,
  the vendor owns the lower tiers (prompt / network / guardrail / credentials) and
  you can't audit them; your real lever is the top tier — least-privilege RBAC +
  data classification / DLP. Treat any bought assistant as a potential confused
  deputy and clamp its data scope accordingly.

---

*Source material: a real production deployment of an LLM-as-brain triage agent
plus a user-facing chat assistant — the credential-isolation and restricted-role
migrations, the token-leak postmortems, the inbound-NAT and tool-server debugging
sessions, and the three-layer defense-in-depth validation. Each rule earned its
place.*

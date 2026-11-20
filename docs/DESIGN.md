# AgentShield — Design

This document records the architecture and the main design decisions. Each decision lists the alternatives we considered and why we didn't pick them. When a decision changes, update its entry and note the date. Don't delete entries.

## 1. Core principle

> **LLMs reason and recommend. Deterministic code authorizes and enforces.**

This principle shapes the rest of the design:

- The gateway's allow/deny decision comes **only** from OPA evaluating Rego against structured input. No model is in the decision path.
- AgentShield's own security agents are **untrusted principals** like any other agent. They have identities, scoped permissions and audited calls. An analyst agent can *request* a suspension; it cannot *perform* one.
- Every state change with real impact (suspending an agent, revoking a permission, quarantining content) is a **proposal**, which a human approves and the gateway executes.
- When OPA, Keycloak or the audit store is unreachable, the gateway **fails closed**.

## 2. Components

| Component | Responsibility | Trust level |
|---|---|---|
| **Gateway** | MCP proxy. Authenticates the agent, builds policy input, queries OPA, enforces, audits, forwards to upstream MCP servers, holds upstream credentials. | Trusted (the enforcement point) |
| **OPA** | Evaluates Rego policies and returns a decision with reasons and obligations. Stateless. | Trusted (the decision point) |
| **Keycloak** | Issues and rotates agent credentials, issues access tokens, handles token exchange for delegation. | Trusted (identity provider) |
| **PostgreSQL** | Append-only audit log, transactional outbox, approval requests, agent registry and status. | Trusted (system of record) |
| **Event dispatcher** | Polls the outbox and triggers agents (e.g. DENY → Security Analyst). | Trusted |
| **Agents** | LLM loop: plan, choose tool, call through the gateway. | **Untrusted** |
| **MCP servers** | Protected resources. In development these are mocks with synthetic data. | Trusted to execute; their **output is untrusted content** |
| **Admin console** | Reviews approvals, incidents and agent status. A minimal web UI or CLI first. | Human |

## 3. Request lifecycle (tool call)

```
agent ──tools/call + Bearer JWT──▶ gateway
  1. authenticate     verify JWT (Keycloak JWKS), check agent status (not suspended)
  2. resolve          tool → upstream server, tool risk metadata, pinned tool schema hash
  3. build input      {subject, tool, arguments, resource, context(session, taint, time, trigger)}
  4. decide           POST to OPA → {allow, reasons[], obligations[]}
  5. enforce          deny → MCP error to agent; require_approval → park + approval request
  6. audit            write the decision row + outbox event in ONE transaction
  7. forward          call upstream with a gateway-held credential; record result metadata
  8. post-process     label the response's provenance (e.g. untrusted external content)
```

Steps 6 and 7 are ordered on purpose: if audit fails, the call is not forwarded.

## 4. Design decisions

### D1. The gateway is an MCP proxy, not an SDK the agent links

**Decision:** Agents connect to the gateway as if it were an MCP server. The gateway aggregates upstream servers and returns only the tools each agent is allowed to *see* (`tools/list` filtering), then authorizes each `tools/call`.

**Why:** Enforcement can't be skipped by a buggy or compromised agent, and it works for agents written in any framework. It also gives us one place to pin tool descriptions, which AgentRed showed matters: poisoned tool metadata was the most effective injection channel.

**Alternatives:** An in-process guard library (bypassable, per-language). A sidecar per agent (operationally heavier for an MVP; we can revisit for Kubernetes).

### D2. Java + Spring Boot for the gateway; Python for agents

**Decision:** The gateway is written in Java 21 / Spring Boot 4, and the agents in Python 3.12.

**Why:** The gateway is long-running, concurrent infrastructure with a lot of security plumbing. Spring Security's OAuth2 resource server, mature JDBC and transactions, and virtual threads fit it well. Python has the best LLM and MCP SDK ecosystem, and AgentRed is already in Python. Splitting the languages also makes the trust boundary visible in the code.

**Alternatives:** An all-Python gateway (FastAPI) would be faster to start, but it blurs the boundary and loses the Spring Security story. Go is a good fit technically but has a weaker OAuth and MCP library ecosystem for our needs.

**Risk:** The Java MCP SDK is younger than the Python and TypeScript ones. Mitigation: the gateway only needs the JSON-RPC message layer and Streamable HTTP transport, which we can implement directly if the SDK gets in the way.

*Update 2026-11-19:* Probing the mock servers (Python MCP SDK 2.3, stateless mode, JSON responses) showed that a tool call is a single HTTP POST of JSON-RPC with a JSON reply: no session and no SSE stream needed. A hand-rolled client and endpoint in the gateway is therefore a small, low-risk fallback. The 0.5 spike now only decides whether the Java SDK adds enough to justify the dependency.

### D3. Agent identity: Keycloak, one OAuth2 client per agent, `private_key_jwt`

**Decision:** Each agent is a confidential Keycloak client. It authenticates with a signed JWT assertion (`private_key_jwt`) instead of a shared secret, and receives short-lived access tokens (5 minutes). The token carries `agent_id`, `agent_type`, `owner` and assigned roles/scopes.

**Why:** Each agent gets a unique, cryptographically verifiable identity with no long-lived bearer secret, and Keycloak handles key rotation and revocation. This is standard workload identity, so it carries over to SPIFFE or cloud workload identity later.

**Delegation (Phase 5+):** When an agent acts for a user (e.g. the Developer Agent working on a user's issue), use OAuth 2.0 Token Exchange (RFC 8693) so the token carries both `sub` (the user) and `act` (the agent). Policies can then require both principals to be authorized.

**Alternatives:** API keys (no rotation, no standard claims). mTLS-only (good transport identity, but poorer authorization claims). SPIFFE/SPIRE (a strong future option, but too heavy for an MVP).

### D4. Policy: OPA + Rego, decisions with reasons and obligations

**Decision:** The gateway calls OPA over HTTP (sidecar or co-located) with a structured input document. The policy returns:

```json
{ "allow": false,
  "reasons": ["tool read_employee_records not granted to agent_type=support"],
  "obligations": [],
  "risk": "high" }
```

Obligations cover things like `require_approval`, `redact:fields`, and `rate_limit`. **Default deny.** Every policy ships with `opa test` unit tests, and CI fails on uncovered rules.

**Why:** Policy as code is versioned, reviewable and testable. Rego can reason about arguments (e.g. `read_service_logs` only for `service in data.agents[a].services`), not only tool names. OPA decision logs give us a second, independent audit trail.

**Alternatives:** Cedar, which is also deterministic, analyzable and simpler to read. It's a strong contender, and we may revisit it for the Access Review Agent's "what can this agent do?" analysis. Hand-written Java rules (not reviewable as policy). LLM-as-judge (rejected by the core principle).

**Data:** Agent→permission grants live in Postgres (the source of truth) and are pushed to OPA as data via the bundle API. Policies stay pure functions of input and data.

### D5. Taint / provenance tracking (Phase 1 stretch, Phase 2 core)

**Decision:** The gateway labels tool *results* that contain untrusted external content (ticket bodies, log lines, web pages). Once a session has ingested untrusted content, `context.session.tainted = true` is passed to OPA. Policy can then raise the bar for high-risk tools: deny them, or require approval.

**Why:** An allow/deny decision on tool name alone stops the flagship scenario only because the Support Agent never held the HR permission. Taint-aware policy also covers the harder case, where the agent *does* hold a sensitive permission but was steered toward using it. It's deterministic and needs no LLM.

**Alternatives:** An LLM-based injection classifier on tool outputs. It may be added later as a *signal* that feeds the Security Analyst, but never as an enforcement input.

### D6. Audit log: append-only Postgres, hash-chained

**Decision:** The `audit_event` table is insert-only: the application role has no UPDATE or DELETE grants. Each row stores `prev_hash` and `hash = sha256(prev_hash || canonical_row)`, which makes tampering detectable. Rows carry `trace_id`, `agent_id`, `session_id`, `tool`, `arguments_digest` (plus redacted arguments), `decision`, `reasons`, `policy_version`.

**Why:** The Security Analyst and Access Review agents read their evidence from this table. It has to be trustworthy and queryable. Postgres is enough at our scale.

**Alternatives:** Writing straight to Kafka or Elasticsearch (more infrastructure for no MVP gain). An immutable ledger DB (overkill).

### D7. Events: transactional outbox in Postgres

**Decision:** The gateway writes `outbox` rows in the same transaction as the audit row. A dispatcher polls with `SELECT … FOR UPDATE SKIP LOCKED` and triggers agent runs (an HTTP call to the agent runner). Delivery is at least once, and agents are idempotent per `event_id`.

**Why:** No dual-write problem and no extra infrastructure. It also fits naturally with the audit transaction.

**Later:** Debezium + Kafka once there are several consumers or the throughput needs it. The outbox schema stays the same.

### D8. Human-in-the-loop: simple approvals table first, Temporal for durable workflows

**Decision:**
- **Phase 2:** An `approval_request` table with a state machine (`PENDING → APPROVED | REJECTED | EXPIRED`), an admin CLI/UI to decide, and a gateway executor that performs the approved action under the *gateway's* own authority.
- **Phase 3+:** Move remediation and approval flows to Temporal once they need timers, escalation, retries and multi-step compensation (e.g. suspend → wait 24h → auto-restore unless confirmed).

**Why:** Temporal is the right tool for durable workflows, but adopting it before we have a real workflow adds cost and no value. The approvals table models the same states, so migrating is mechanical.

**Approval-bypass resistance:** An approval is bound to the exact `(action, target, parameters_hash)`. Agents cannot create APPROVED rows, and no tool exposes that. Red Team tests specifically target this.

### D9. Agent runtime: a plain Python tool-calling loop, model-agnostic

**Decision:** `agents/common` provides:
- `ModelAdapter`, with Claude as the default and OpenAI and a local model (Ollama) as alternatives
- `GatewayMCPClient`, which handles the token from Keycloak, MCP over Streamable HTTP and trace propagation
- `AgentLoop`: system prompt → model → tool calls → gateway → results, with a step budget and a stop condition
- structured run records (every step, emitted as OTel spans)

**Why:** A loop of about 200 lines is easy to explain, and every security-relevant step is visible. AgentRed showed that framework choice changes security behavior, so we'd rather adopt a framework on purpose later than by default.

**Alternatives:** LangGraph, which we'd adopt for the Developer and SRE agents if they need branching, checkpointed graphs. Agent SDKs: possible later. Because the gateway is framework-agnostic, mixing frameworks is a feature: it shows the boundary holds regardless of framework.

### D10. Internal security agents are governed like everyone else

**Decision:** The Security Analyst, Access Review and Red Team agents get their own Keycloak clients and policies:
- **Security Analyst:** read-only access to audit, traces, permissions and policy decisions. `create_security_incident` is allowed. `request_agent_suspension` creates an approval request and never suspends directly.
- **Access Review:** read-only access to grants and usage statistics. Its output is recommendations only.
- **Red Team:** can call only sandbox-tenant tools against synthetic data, with no production upstreams. The gateway enforces this by tenant routing, not by prompt.

**Why:** Dogfooding. It also defends against the obvious attack: inject the analyst through the very log line it's investigating. The analyst reads attacker-controlled content by design.

### D11. Observability: OpenTelemetry end to end

**Decision:** W3C `traceparent` is propagated from the trigger event → agent run → each model call and tool call → gateway → OPA → upstream MCP server. Span attributes include `agent.id`, `tool.name`, `policy.decision` and `policy.version`. Jaeger runs locally.

**Why:** "Why did the agent do that?" needs the whole chain. The Security Analyst's `get_execution_trace` tool reads the audit log joined on `trace_id`; it doesn't need Jaeger.

### D12. Protected resources: mock MCP servers with synthetic data

**Decision:** Python MCP servers (`tickets`, `incidents`, `service-logs`, `hr-records`, later `github` and `k8s`) serve deterministic synthetic data. Fixtures include planted injections and canary secrets, reusing AgentRed's canary convention.

**Why:** The demos are reproducible offline, nothing real is at risk, and Red Team scenarios get stable ground truth.

**Implementation notes:** The servers are built on the Python MCP SDK 2.x (`MCPServer`, formerly `FastMCP`) and served statelessly over Streamable HTTP with DNS-rebinding protection on (an explicit `Host` allowlist per container). Each server records every invocation in an in-memory call log exposed at `/_calls`. That route is plain HTTP, not an MCP tool, so agents can't see it, and integration tests use it to prove that a denied call never reached the upstream.

### D13. Local deployment: Docker Compose

**Decision:** A single `docker compose up` starts Postgres, Keycloak (with an imported realm), OPA, Jaeger, the gateway, the mock MCP servers, the dispatcher and the agent runner. Kubernetes manifests come only with the SRE Agent phase.

## 5. Threat model (summary)

| Threat | Primary control | Detected by |
|---|---|---|
| Prompt injection → unauthorized tool | Per-agent grants, default deny (D4) | DENY event → Security Analyst |
| Injection → misuse of a *granted* sensitive tool | Taint-aware policy, approval obligations (D5, D8) | Red Team, analyst |
| Poisoned tool descriptions | Gateway pins tool schema hashes; mismatches are blocked (D1) | Gateway alert |
| Stolen agent credential | `private_key_jwt`, 5-minute tokens, agent suspension check per call (D3) | Anomaly in audit log |
| Privilege creep | Usage-based review (Phase 4) | Access Review Agent |
| Approval bypass | Approvals bound to action hash, not agent-writable (D8) | Red Team |
| Data exfiltration via arguments | Argument policies, egress allowlists, canary detection | Red Team, audit |
| Tampering with audit | Insert-only grants + hash chain (D6) | Chain verification job |
| Security agent itself injected | Same governance, read-only, propose-only (D10) | Red Team |

Out of scope for now: model supply chain, host compromise, and side channels in the model provider.

## 6. Open questions

1. **Cedar vs. Rego.** Starting with Rego; revisit when building the Access Review Agent, which benefits from policy analysis.
2. **Java MCP SDK maturity.** Spike in Phase 0. Fallback: a hand-rolled JSON-RPC layer.
3. **Admin console.** CLI only, or a small web UI for the demo? Leaning toward a minimal web UI in Phase 2, because approvals are the demo's climax.
4. **Model for agents.** The default is a current Claude model. Do we also run each scenario on a second provider to show model independence?
5. **Where AgentRed lives.** Depend on it as a package (preferred) or vendor scenarios into `agents/red_team`?

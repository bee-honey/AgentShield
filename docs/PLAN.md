# AgentShield — Implementation Plan

**MVP = Phases 0–2:** two working agents (Support and Security Analyst) behind an enforced, audited, traced security boundary, plus a human approval step. Phases 3–6 build on top of it.

Each phase ends with a **demo** that can be run with one command, and with **acceptance criteria** that are checked automatically where possible.

---

## Phase 0 — Foundations

**Goal:** The secure path works end to end with a scripted (non-LLM) client.

| # | Task | Notes | Status |
|---|---|---|---|
| 0.1 | Repo skeleton, `deploy/docker-compose.yml`, Makefile, CI (GitHub Actions) | Postgres, Keycloak, OPA, Jaeger | ✅ |
| 0.2 | Keycloak realm export: `agentshield` realm, clients for `support-agent` and `security-analyst-agent`, `private_key_jwt` | D3. Keys generated per checkout by `make keys` | ✅ |
| 0.3 | Postgres schema + migrations (Flyway): `agent`, `agent_grant`, `audit_event` (hash chain), `outbox`, `approval_request` | D6, D7, D8. Owner/app role split, append-only triggers | ✅ |
| 0.4 | Mock MCP servers: `tickets`, `incidents`, `service-logs`, `hr-records` with synthetic fixtures | D12 | ✅ |
| 0.5 | **Spike:** Java MCP SDK vs. hand-rolled Streamable HTTP JSON-RPC. Pick one and record it in DESIGN.md | D2 risk (reduced, see D2 update) | |
| 0.6 | Gateway: JWT auth, tool registry and routing, `tools/list` filtering, `tools/call` → OPA → forward | D1. JWT auth done | 🟡 |
| 0.7 | Rego policy v1: default deny, per-agent-type tool grants, argument constraints for `read_service_logs` + `opa test` | D4 | |
| 0.8 | Audit write + outbox in one transaction; fail closed if OPA or the DB is down | D6, D7 | |
| 0.9 | OTel instrumentation in the gateway; trace visible in Jaeger | D11 | |

**Demo:** `make demo-phase0`. A script authenticates as `support-agent`, calls an allowed tool (ALLOW, forwarded) and then `read_employee_records` (DENY), and prints the audit rows.

**Acceptance:**
- Integration test: allowed call reaches upstream; denied call never reaches upstream (asserted by the mock server's call log).
- Gateway returns an error and forwards nothing when OPA is stopped.
- The hash chain verifies after the test run.
- `opa test policies/` passes in CI.

---

## Phase 1 — Support Agent (real LLM)

**Goal:** A real LLM agent picks tools, hits the boundary, and gets stopped.

| # | Task | Notes |
|---|---|---|
| 1.1 | `agents/common`: `ModelAdapter` (Claude default, OpenAI optional), `GatewayMCPClient` (token + MCP), `AgentLoop` with step budget, OTel spans | D9 |
| 1.2 | Support Agent: system prompt, task = investigate a ticket and draft a reply via `draft_ticket_response` | |
| 1.3 | Trigger: new ticket inserted → outbox event → dispatcher → agent runner | D7 |
| 1.4 | Flagship fixture: a payment-failure ticket whose logs contain an injected instruction to read employee records | |
| 1.5 | Run record: per-run timeline (model turns, tool calls, decisions) queryable by `run_id` / `trace_id` | |
| 1.6 | *Stretch:* gateway taint labeling of tool results + `context.session.tainted` in policy input | D5 |

**Demo:** `make demo-support`. Insert a ticket, then watch a live trace: `search_previous_incidents` ALLOW → `read_service_logs` ALLOW → `read_employee_records` **DENY** → the agent still drafts a reply.

**Acceptance:**
- Over N=10 runs with the injection fixture: 0 unauthorized calls forwarded (any number may be *attempted*), and the task completes in ≥ 9/10.
- Offline mode with a scripted "naive" model replays the attack without an API key, for CI.

---

## Phase 2 — Security Analyst Agent + approvals (MVP complete)

**Goal:** A DENY triggers an AI investigation, which proposes remediation that a human approves and the gateway executes.

| # | Task | Notes |
|---|---|---|
| 2.1 | Security event rules (deterministic): DENY on high-risk tool, repeated denies, schema-hash mismatch → `security_event` outbox | |
| 2.2 | Internal MCP server `shield-internal` exposing `query_audit_logs`, `get_agent_permissions`, `get_execution_trace`, `get_policy_decision`, `get_recent_security_events`, `create_security_incident`, `request_agent_suspension`, `request_content_quarantine` | D10 |
| 2.3 | Policies for the analyst: read-only, and `request_*` produces an `approval_request` | D8, D10 |
| 2.4 | Security Analyst Agent: investigation prompt, structured incident report (summary, evidence with audit IDs, suspected source, recommended actions) | |
| 2.5 | Approval flow: admin CLI + minimal web page listing pending approvals with evidence; approve/reject | D8 |
| 2.6 | Remediation executor in the gateway: suspend agent (blocked at auth step), quarantine content (mock server hides record), notify (log/webhook) | |
| 2.7 | Taint-aware policy promoted from stretch to core | D5 |
| 2.8 | Analyst injection test: the poisoned log also tries to manipulate the analyst; verify propose-only holds | D10 |

**Demo:** `make demo-mvp`. The full flagship scenario from the README, ending with the admin approving and the suspended Support Agent's next call being rejected.

**Acceptance:**
- The incident report cites the correct poisoned record ID in ≥ 8/10 runs.
- No remediation executes without an APPROVED row bound to the exact action hash.
- An analyst prompted to "just suspend it directly" cannot: the gateway denies the call.

---

## Phase 3 — Red Team Agent (AgentRed integration)

- Package AgentRed scenarios (egress, authz, approval, poisoning, rag, ssrf) as a target adapter that points at AgentShield-governed agents.
- Sandbox tenant: the gateway routes the red-team tenant to synthetic upstreams only.
- New scenarios specific to AgentShield: approval bypass, suspended-agent token reuse, tool-schema swap, analyst injection.
- CI gate: changes to `policies/`, tool definitions or agent configs run the suite and fail on regressions against a baseline.
- Bring in Temporal for scheduled runs and multi-step remediation (D8 migration).

## Phase 4 — Access Review Agent

- Usage aggregation: permission → call counts, last used, denied attempts (from `audit_event`).
- Risk scoring per permission (static tool risk × blast radius).
- The agent produces a review: unused high-risk grants, grants used only under taint, indirect permissions.
- Output: an approval request per recommended revocation. Note: an unused permission is not necessarily an unnecessary one.
- Evaluate Cedar for policy analysis (open question 1).

## Phase 5 — Developer Agent

- GitHub MCP server against a sandbox repo; delegated identity via token exchange (`sub`=user, `act`=agent).
- Policies on `repo:write` paths, PR creation only, no `repo:delete` / admin.
- Possibly LangGraph for the plan → edit → test → PR loop.

## Phase 6 — SRE Agent

- Kubernetes (kind) + Prometheus alerts as triggers; read-only diagnostics allowed, mutating actions require approval.
- Kubernetes manifests for AgentShield itself.

---

## Cross-cutting conventions

- **Every new tool** needs a risk level, an owner and a Rego rule with tests before it's routable.
- **Every agent** needs a Keycloak client, a grant set and at least one Red Team scenario (from Phase 3).
- **Secrets** live in `.env` (gitignored) for local development only. `.env.example` is committed.
- **Decisions** that change the design are recorded in `docs/DESIGN.md`.

## Immediate next steps

1. Phase 0.5 spike, then 0.6: the gateway MCP endpoint (`tools/list` filtering, `tools/call` → OPA → forward).
2. Phase 0.7 Rego policy v1 with tests.
3. Phase 0.8 audit hash chain + outbox, then the `make demo-phase0` script.

# AgentShield

**An agentic security and identity governance platform for AI agents.**

AgentShield sits between LLM-powered agents and the resources they act on. Every tool call an agent makes goes through an MCP gateway that authenticates the agent, asks a policy engine for a decision, enforces it, and records it. AgentShield also runs its own security agents that investigate suspicious behavior, review agent permissions and attack other agents to test the boundary.

> **AI agents investigate, reason and recommend. Deterministic security infrastructure authorizes and enforces.**

No LLM ever decides whether a tool call is allowed. Agents, including AgentShield's own security agents, can only propose actions; policy code makes the decision, and high-impact changes need a human's approval.

> **Status:** Phase 0 (foundations) in progress. The local stack runs, agents authenticate with `private_key_jwt`, and the schema and mock resources are in place. The gateway's MCP endpoint and the policies come next. See [docs/PLAN.md](docs/PLAN.md).

## Quickstart

Requires Docker, Java 21 and Python 3.12+.

```bash
make up            # creates .env, generates dev agent keys, starts the stack
make token         # decoded access token for support-agent (AGENT=... for others)
make test          # mock server tests + gateway tests (Testcontainers)
make down          # stop (make clean also deletes data)
```

| Service | URL |
|---|---|
| Gateway | http://localhost:8090 (`GATEWAY_PORT` in `.env`) |
| Keycloak | http://localhost:8180 (admin / see `.env`) |
| OPA | http://localhost:8181 |
| Jaeger | http://localhost:16686 |
| Mock MCP servers (debug only) | http://localhost:9101–9104/mcp |

## Why

Agents are moving from chat to action: they read tickets, query logs, open pull requests and restart services. The model is now part of the attack surface. A prompt injection in a retrieved document can make a well-behaved agent call a tool it should never touch. Research from [AgentRed](https://github.com/bee-honey/AgentRed) showed that **controls enforced in code hold where prompt-level controls do not**. AgentShield is the production-shaped version of that lesson:

- Every agent has a **verifiable identity**, not a shared API key.
- Every tool call is **authorized per call, per argument** against policy as code.
- Every decision is **audited and traceable** from the triggering event to the resource.
- Suspicious behavior is **investigated automatically** and remediation goes through **human approval**.
- The boundary is **continuously tested** by an adversarial agent.

## Architecture at a glance

```
           ┌──────────────────────── Agents (Python, LLM-powered) ────────────────────────┐
           │  Consumers:  Support · Developer · SRE                                       │
           │  Internal:   Security Analyst · Access Review · Red Team                     │
           └───────────────┬──────────────────────────────────────────────────────────────┘
                           │ MCP (Streamable HTTP) + OAuth2 bearer token
                           ▼
 ┌──────────┐   token   ┌─────────────────────────────┐  decision  ┌─────────────┐
 │ Keycloak │◀─────────▶│   AgentShield Gateway        │◀──────────▶│  OPA + Rego │
 │ (agent   │  verify   │   (Java / Spring Boot)       │            │  policies   │
 │ identity)│           │  authn → authz → enforce →   │            └─────────────┘
 └──────────┘           │  audit → forward             │
                        └──────┬──────────────┬────────┘
                               │ MCP          │ audit + events (outbox)
                               ▼              ▼
                ┌──────────────────────┐   ┌──────────────────────────────┐
                │ Protected resources  │   │ PostgreSQL                   │
                │ (MCP servers: tickets│   │ audit log · outbox · approvals│
                │  logs, HR, GitHub…)  │   └──────────────┬───────────────┘
                └──────────────────────┘                  │ security events
                                                          ▼
                                            Security Analyst Agent → proposes
                                            remediation → admin approves →
                                            gateway enforces
```

OpenTelemetry traces connect each step, from the trigger through the LLM's choice of tool and the policy decision to the downstream call.

## The agents

| Agent | Role | Trigger | Phase |
|---|---|---|---|
| Support Agent | Investigates customer tickets, drafts responses | New ticket | 1 |
| Security Analyst Agent | AI SOC analyst: investigates denials and anomalies, proposes remediation | Security event | 2 |
| Red Team Agent | Attacks other agents in a sandbox (built on AgentRed) | Config/policy change, schedule | 3 |
| Access Review Agent | Finds excessive, unused or risky agent permissions | Schedule | 4 |
| Developer Agent | Investigates GitHub issues, writes code, opens PRs | Assigned issue | 5 |
| SRE Agent | Investigates incidents, proposes remediation | Monitoring alert | 6 |

The Support, Developer and SRE agents **consume** AgentShield. The Security Analyst, Access Review and Red Team agents are **part of** AgentShield, and they go through the same gateway and policy engine as every other agent.

## Flagship scenario

1. A ticket arrives about a payment failure, which triggers the Support Agent.
2. The agent calls `search_previous_incidents` and `read_service_logs`. The gateway allows both.
3. A log entry contains an injected instruction to pull employee records.
4. The agent calls `read_employee_records`. The gateway **denies** the call: the policy doesn't grant that tool to the agent.
5. The denial emits a security event, which triggers the Security Analyst Agent.
6. The analyst pulls the execution trace and audit log, finds the poisoned log entry, and proposes three actions: quarantine the content, suspend the agent, notify the admin.
7. An admin approves, and the gateway carries out the remediation.

## Tech stack

| Concern | Choice |
|---|---|
| Gateway | Java 21, Spring Boot 4 |
| Agents | Python 3.12, a plain tool-calling loop with a model adapter (Claude by default; OpenAI and local models swappable) |
| Tool protocol | MCP (Streamable HTTP) |
| Agent identity | Keycloak (OAuth2 client credentials with `private_key_jwt`; token exchange for delegation) |
| Policy | Open Policy Agent + Rego |
| Store / events | PostgreSQL (audit log, transactional outbox, approvals) |
| Durable workflows | Temporal (from Phase 2, for approvals) |
| Tracing | OpenTelemetry → Jaeger |
| Security evals | AgentRed |
| Local runtime | Docker Compose |

Each choice and its alternatives are covered in [docs/DESIGN.md](docs/DESIGN.md).

## Repository layout (planned)

```
gateway/            Spring Boot MCP gateway
policies/           Rego policies + policy tests
agents/
  common/           model adapter, MCP client, agent loop, tracing
  support/          Support Agent
  security_analyst/ Security Analyst Agent
  red_team/         AgentRed integration
  access_review/    Access Review Agent
mcp-servers/        mock protected resources with synthetic data
deploy/             docker-compose, Keycloak realm, OTel config
docs/               plan, design decisions
```

## Docs

- [docs/PLAN.md](docs/PLAN.md): phased roadmap, milestones and acceptance criteria
- [docs/DESIGN.md](docs/DESIGN.md): architecture and design decisions, with alternatives considered

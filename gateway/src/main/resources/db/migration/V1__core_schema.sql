-- AgentShield core schema. See docs/DESIGN.md (D4, D6, D7, D8).
-- Runs as the schema owner. Runtime role: ${appRole}.

-- ---------------------------------------------------------------------------
-- Agent registry
-- ---------------------------------------------------------------------------
CREATE TABLE agent (
    agent_id      text PRIMARY KEY,            -- matches the `agent_id` token claim
    agent_type    text        NOT NULL,        -- matches the `agent_type` token claim
    display_name  text        NOT NULL,
    owner         text        NOT NULL,        -- accountable human/team
    status        text        NOT NULL DEFAULT 'ACTIVE'
                  CHECK (status IN ('ACTIVE', 'SUSPENDED', 'DISABLED')),
    status_reason text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Tool registry: every routable tool must be registered with a risk level and
-- owner. Upstream URLs live in gateway config; `upstream` is the config key.
-- ---------------------------------------------------------------------------
CREATE TABLE tool (
    tool_name        text PRIMARY KEY,
    upstream         text        NOT NULL,
    risk             text        NOT NULL CHECK (risk IN ('low', 'medium', 'high', 'critical')),
    owner            text        NOT NULL,
    untrusted_output boolean     NOT NULL DEFAULT false, -- result may carry attacker text (D5 taint)
    schema_hash      text,                               -- pinned sha256 of the tool definition (D1)
    enabled          boolean     NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Grants: the source of truth for "which agent may call which tool, with what
-- argument constraints". Pushed to OPA as data (D4).
-- ---------------------------------------------------------------------------
CREATE TABLE agent_grant (
    agent_id    text        NOT NULL REFERENCES agent (agent_id),
    tool_name   text        NOT NULL REFERENCES tool (tool_name),
    constraints jsonb       NOT NULL DEFAULT '{}'::jsonb,
    granted_by  text        NOT NULL,
    granted_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz,
    PRIMARY KEY (agent_id, tool_name)
);

-- ---------------------------------------------------------------------------
-- Audit log: append-only and hash-chained (D6).
--   hash = sha256(prev_hash || canonical(row)), computed by the gateway while
--   holding the row lock on audit_chain_head, so the chain is strictly ordered.
-- ---------------------------------------------------------------------------
CREATE TABLE audit_event (
    seq              bigint PRIMARY KEY,
    event_id         uuid        NOT NULL UNIQUE,
    occurred_at      timestamptz NOT NULL,
    event_type       text        NOT NULL,           -- tool_call | auth_failure | remediation | ...
    agent_id         text,                           -- null when authentication failed
    session_id       text,
    run_id           text,
    trace_id         text,
    tool_name        text,
    arguments        jsonb,                          -- redacted arguments
    arguments_digest text,                           -- sha256 of the raw canonical arguments
    decision         text CHECK (decision IN ('ALLOW', 'DENY', 'REQUIRE_APPROVAL', 'ERROR')),
    reasons          jsonb       NOT NULL DEFAULT '[]'::jsonb,
    obligations      jsonb       NOT NULL DEFAULT '[]'::jsonb,
    policy_version   text,
    upstream_status  text,                           -- ok | error | not_forwarded
    latency_ms       integer,
    prev_hash        text        NOT NULL,
    hash             text        NOT NULL UNIQUE
);

CREATE INDEX audit_event_agent_time_idx ON audit_event (agent_id, occurred_at DESC);
CREATE INDEX audit_event_trace_idx      ON audit_event (trace_id);
CREATE INDEX audit_event_decision_idx   ON audit_event (decision, occurred_at DESC);

CREATE TABLE audit_chain_head (
    id        smallint PRIMARY KEY CHECK (id = 1),
    last_seq  bigint NOT NULL,
    last_hash text   NOT NULL
);
INSERT INTO audit_chain_head (id, last_seq, last_hash)
VALUES (1, 0, repeat('0', 64));

-- Defense in depth: even the owner cannot rewrite history without first
-- dropping these triggers (which is itself a visible schema change).
CREATE FUNCTION forbid_audit_mutation() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    RAISE EXCEPTION 'audit_event is append-only: % is not permitted', TG_OP;
END;
$$;

CREATE TRIGGER audit_event_no_update_delete
    BEFORE UPDATE OR DELETE ON audit_event
    FOR EACH ROW EXECUTE FUNCTION forbid_audit_mutation();

CREATE TRIGGER audit_event_no_truncate
    BEFORE TRUNCATE ON audit_event
    FOR EACH STATEMENT EXECUTE FUNCTION forbid_audit_mutation();

-- ---------------------------------------------------------------------------
-- Transactional outbox (D7). Written in the same transaction as audit_event.
-- ---------------------------------------------------------------------------
CREATE TABLE outbox (
    id             bigserial PRIMARY KEY,
    event_id       uuid        NOT NULL UNIQUE,
    event_type     text        NOT NULL,             -- e.g. tool_call.denied, security_event
    aggregate_type text        NOT NULL,             -- e.g. agent, approval_request
    aggregate_id   text        NOT NULL,
    payload        jsonb       NOT NULL,
    trace_id       text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    available_at   timestamptz NOT NULL DEFAULT now(),
    attempts       integer     NOT NULL DEFAULT 0,
    last_error     text,
    processed_at   timestamptz
);

CREATE INDEX outbox_pending_idx ON outbox (available_at) WHERE processed_at IS NULL;

-- ---------------------------------------------------------------------------
-- Approval requests (D8). An approval authorizes exactly one action: it is
-- bound to action_hash = sha256(action || target || parameters_hash).
-- ---------------------------------------------------------------------------
CREATE TABLE approval_request (
    id              uuid PRIMARY KEY,
    action          text        NOT NULL,            -- e.g. suspend_agent, quarantine_content
    target          text        NOT NULL,            -- e.g. agent id, content record id
    parameters      jsonb       NOT NULL DEFAULT '{}'::jsonb,
    parameters_hash text        NOT NULL,
    action_hash     text        NOT NULL,
    requested_by    text        NOT NULL,            -- agent id or human principal
    requester_kind  text        NOT NULL CHECK (requester_kind IN ('agent', 'human')),
    justification   text        NOT NULL,
    evidence        jsonb       NOT NULL DEFAULT '[]'::jsonb, -- audit seqs, trace ids, record ids
    status          text        NOT NULL DEFAULT 'PENDING'
                    CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED', 'EXPIRED', 'EXECUTED')),
    decided_by      text,
    decided_at      timestamptz,
    decision_note   text,
    executed_at     timestamptz,
    expires_at      timestamptz NOT NULL,
    trace_id        text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (status = 'PENDING' OR decided_at IS NOT NULL OR status = 'EXPIRED')
);

CREATE INDEX approval_request_pending_idx ON approval_request (created_at) WHERE status = 'PENDING';

-- ---------------------------------------------------------------------------
-- Runtime grants (least privilege)
-- ---------------------------------------------------------------------------
GRANT SELECT, UPDATE         ON agent            TO ${appRole};  -- status changes (suspension)
GRANT SELECT                 ON tool             TO ${appRole};
GRANT SELECT                 ON agent_grant      TO ${appRole};
GRANT SELECT, INSERT         ON audit_event      TO ${appRole};  -- no UPDATE/DELETE, ever
GRANT SELECT, UPDATE         ON audit_chain_head TO ${appRole};
GRANT SELECT, INSERT, UPDATE ON outbox           TO ${appRole};
GRANT USAGE                  ON SEQUENCE outbox_id_seq TO ${appRole};
GRANT SELECT, INSERT, UPDATE ON approval_request TO ${appRole};

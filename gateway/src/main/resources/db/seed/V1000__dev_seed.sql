-- Dev-only seed data (loaded with the `dev` profile). Synthetic agents, tools
-- and grants for the local demo. Never loaded in production.

INSERT INTO agent (agent_id, agent_type, display_name, owner) VALUES
    ('support-agent',          'support',          'Support Agent',          'support-platform-team'),
    ('security-analyst-agent', 'security_analyst', 'Security Analyst Agent', 'security-team');

INSERT INTO tool (tool_name, upstream, risk, owner, untrusted_output) VALUES
    ('list_open_tickets',         'tickets',      'low',    'support-platform-team', false),
    ('get_ticket',                'tickets',      'low',    'support-platform-team', true),   -- customer-written body
    ('draft_ticket_response',     'tickets',      'medium', 'support-platform-team', false),
    ('search_previous_incidents', 'incidents',    'low',    'sre-team',              false),
    ('list_services',             'service-logs', 'low',    'sre-team',              false),
    ('read_service_logs',         'service-logs', 'medium', 'sre-team',              true),   -- log lines may carry attacker text
    ('read_employee_records',     'hr-records',   'high',   'hr-platform-team',      false);

-- The Support Agent is deliberately NOT granted read_employee_records.
INSERT INTO agent_grant (agent_id, tool_name, constraints, granted_by) VALUES
    ('support-agent', 'list_open_tickets',         '{}',                                               'seed'),
    ('support-agent', 'get_ticket',                '{}',                                               'seed'),
    ('support-agent', 'draft_ticket_response',     '{}',                                               'seed'),
    ('support-agent', 'search_previous_incidents', '{}',                                               'seed'),
    ('support-agent', 'list_services',             '{}',                                               'seed'),
    ('support-agent', 'read_service_logs',         '{"service": ["payments-api", "checkout-web"]}',    'seed');

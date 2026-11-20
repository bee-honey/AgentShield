# AgentShield tool-call authorization.
#
# Phase 0 placeholder: default deny for everything. Real grants, argument
# constraints and tests arrive in task 0.7 (see docs/PLAN.md).
package agentshield.authz

import rego.v1

default decision := {
	"allow": false,
	"reasons": ["default deny: no policy rules defined yet"],
	"obligations": [],
}

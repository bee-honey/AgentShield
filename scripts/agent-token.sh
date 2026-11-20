#!/usr/bin/env bash
# Obtain an access token for an agent using OAuth2 client credentials with
# private_key_jwt (RFC 7523). Dependency-free: only openssl + curl.
#
#   scripts/agent-token.sh support-agent            # prints the access token
#   scripts/agent-token.sh support-agent --claims   # prints decoded token claims
set -euo pipefail

AGENT="${1:?usage: agent-token.sh <agent-id> [--claims]}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="$ROOT/deploy/.secrets/agents/$AGENT.key"
ISSUER="${OIDC_ISSUER:-http://localhost:8180/realms/agentshield}"
TOKEN_URL="$ISSUER/protocol/openid-connect/token"

[[ -f "$KEY" ]] || { echo "no key for $AGENT; run 'make keys'" >&2; exit 1; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now="$(date +%s)"
header='{"alg":"RS256","typ":"JWT"}'
payload="$(printf '{"iss":"%s","sub":"%s","aud":"%s","jti":"%s","iat":%d,"exp":%d}' \
  "$AGENT" "$AGENT" "$ISSUER" "$(openssl rand -hex 16)" "$now" "$((now + 60))")"
signing_input="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
signature="$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$KEY" | b64url)"
assertion="$signing_input.$signature"

response="$(curl -sS --fail-with-body "$TOKEN_URL" \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode "client_id=$AGENT" \
  --data-urlencode client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
  --data-urlencode "client_assertion=$assertion")" || { echo "$response" >&2; exit 1; }

token="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"

if [[ "${2:-}" == "--claims" ]]; then
  printf '%s' "$token" | cut -d. -f2 | python3 -c '
import base64, json, sys
p = sys.stdin.read().strip(); p += "=" * (-len(p) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(p)), indent=2))'
else
  printf '%s\n' "$token"
fi

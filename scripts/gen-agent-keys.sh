#!/usr/bin/env bash
# Generate a dev keypair + self-signed certificate per agent, then render the
# Keycloak realm import with each agent's certificate embedded.
#
# Agents authenticate to Keycloak with private_key_jwt (DESIGN.md D3): they sign
# a client assertion with their private key and Keycloak verifies it against
# the certificate registered on the agent's client. No shared secrets.
#
# Outputs (gitignored):
#   deploy/.secrets/agents/<agent>.key   private key (PKCS#8 PEM)  -> used by the agent
#   deploy/.secrets/agents/<agent>.crt   certificate               -> registered in Keycloak
#   deploy/.generated/keycloak/agentshield-realm.json
#
# Idempotent: existing keys are kept unless --force is given.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS="$ROOT/deploy/.secrets/agents"
OUT="$ROOT/deploy/.generated/keycloak"
TEMPLATE="$ROOT/deploy/keycloak/agentshield-realm.template.json"
AGENTS=(support-agent security-analyst-agent)

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

mkdir -p "$SECRETS" "$OUT"
chmod 700 "$ROOT/deploy/.secrets" "$SECRETS"

realm="$(cat "$TEMPLATE")"
for agent in "${AGENTS[@]}"; do
  key="$SECRETS/$agent.key"
  crt="$SECRETS/$agent.crt"
  if [[ $FORCE -eq 1 || ! -f "$key" || ! -f "$crt" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
      -subj "/CN=$agent/O=AgentShield Dev" \
      -keyout "$key" -out "$crt" 2>/dev/null
    chmod 600 "$key"
    echo "generated key for $agent"
  else
    echo "keeping existing key for $agent"
  fi
  cert_b64="$(grep -v -- '-----' "$crt" | tr -d '\n')"
  placeholder="__CERT_$(echo "$agent" | tr 'a-z-' 'A-Z_')__"
  realm="${realm//$placeholder/$cert_b64}"
done

if grep -q '__CERT_' <<<"$realm"; then
  echo "error: unrendered certificate placeholder left in realm template" >&2
  exit 1
fi
printf '%s\n' "$realm" > "$OUT/agentshield-realm.json"
echo "rendered $OUT/agentshield-realm.json"

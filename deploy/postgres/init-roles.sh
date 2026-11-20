#!/usr/bin/env bash
# Runs once on first container start (docker-entrypoint-initdb.d).
#
# Two roles, least privilege (DESIGN.md D6):
#   agentshield_owner  owns the schema; used ONLY by Flyway migrations
#   agentshield_app    runtime role for the gateway; table grants are set by
#                      migrations (e.g. INSERT/SELECT only on audit_event)
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<SQL
CREATE ROLE agentshield_owner LOGIN PASSWORD '${AGENTSHIELD_OWNER_PASSWORD}';
CREATE ROLE agentshield_app   LOGIN PASSWORD '${AGENTSHIELD_APP_PASSWORD}';
CREATE DATABASE agentshield OWNER agentshield_owner;
REVOKE ALL ON DATABASE agentshield FROM PUBLIC;
GRANT CONNECT ON DATABASE agentshield TO agentshield_app;
SQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname agentshield <<SQL
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO agentshield_app;
SQL

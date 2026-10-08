#!/usr/bin/env bash
# Replays supabase/migrations/*.sql, in version order, into a fresh SCRATCH database on a LOCAL Postgres.
#
# LOCAL-REPLAY ONLY. It refuses any connection that is not a local socket or loopback address, installs
# the stand-ins for the hosted-only pieces first (support/local_supabase_shims.sql: API roles, Vault,
# pg_cron, pg_net - all inert), and neutralises the two `create extension pg_cron / pg_net` lines because
# the stand-in schemas replace those extensions locally. Nothing here can reach a hosted project.
#
# Usage:  replay_migrations.sh <database> [--before <migration-version-prefix>]
#   <database>                      created fresh (an existing one of that name is DROPPED)
#   --before 20261007120000         stop before that migration (to test applying it on top of older data)
# Environment: libpq variables (PGHOST, PGPORT, PGUSER). Defaults: socket /var/run/postgresql, port 55432.
set -euo pipefail

DB="${1:?usage: replay_migrations.sh <database> [--before <version>]}"
BEFORE=""
if [ "${2:-}" = "--before" ]; then BEFORE="${3:?--before needs a migration version prefix}"; fi

export PGHOST="${PGHOST:-/var/run/postgresql}" PGPORT="${PGPORT:-55432}" PGUSER="${PGUSER:-postgres}"
case "$PGHOST" in
  /*|localhost|127.0.0.1|::1) ;;
  *) echo "REFUSING: PGHOST=$PGHOST is not a local socket or loopback address" >&2; exit 2 ;;
esac
case "$DB" in
  postgres|template0|template1) echo "REFUSING: will not replay into $DB" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT

dropdb --if-exists "$DB" >/dev/null 2>&1
createdb "$DB"
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$HERE/local_supabase_shims.sql" >/dev/null

applied=0
for file in "$REPO"/supabase/migrations/*.sql; do
  name="$(basename "$file")"
  if [ -n "$BEFORE" ] && [[ "$name" > "$BEFORE" || "$name" == "$BEFORE"* ]]; then break; fi
  sed -E 's/^(create extension if not exists (pg_cron|pg_net) with schema extensions;)/-- local replay: \1/I' "$file" \
    | psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f - >/dev/null 2>"$ERR" \
    || { echo "FAILED at $name" >&2; cat "$ERR" >&2; exit 1; }
  applied=$((applied + 1))
done
echo "replayed $applied migrations into $DB"

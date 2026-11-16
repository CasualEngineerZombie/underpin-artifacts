#!/usr/bin/env bash
#
# verify-pgvector.sh — prove the built pgvector extension LOADS and COMPUTES.
#
# This is a separate script because PostgreSQL refuses to run as root: initdb
# exits with "cannot be run as root", and the scratch server it starts is a
# server too. The build and the install step, by contrast, need write access
# to the PostgreSQL installation's lib/ and share/ directories — which is a
# root (or sudo) operation. So the two halves run at different privileges, and
# this file is the half that must NOT be root.
#
# A build that compiles but does not load is worse than no build: the install
# would provision a cluster whose vector extension silently refuses to
# activate, and the first embedding insert would fail with a message that
# points at the embedding code rather than at the extension.

set -euo pipefail

say() { printf '==> %s\n' "$*"; }
abort() { printf 'verify-pgvector: ABORT: %s\n' "$*" >&2; exit 1; }

PG_CONFIG="${PG_CONFIG:-pg_config}"
command -v "$PG_CONFIG" >/dev/null 2>&1 || abort "$PG_CONFIG not found"

PGBIN="$("$PG_CONFIG" --bindir)"
PGDATA="$(mktemp -d)"
SOCKDIR="$(mktemp -d)"
VERIFY_PORT=55433
VERIFY_DB="pgvector_verify_$$"

cleanup() {
	"$PGBIN/pg_ctl" -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
	rm -rf "$PGDATA" "$SOCKDIR"
}
trap cleanup EXIT

say "initialising a scratch cluster"
"$PGBIN/initdb" -D "$PGDATA" -U postgres --no-locale >/dev/null 2>&1 \
	|| abort "could not initialise the verification cluster"

say "starting the scratch server"
"$PGBIN/pg_ctl" -D "$PGDATA" -o "-k $SOCKDIR -p $VERIFY_PORT -h ''" -w -l "$PGDATA/server.log" start >/dev/null \
	|| abort "could not start the verification server"

psql_super() { psql -h "$SOCKDIR" -p "$VERIFY_PORT" -U postgres -v ON_ERROR_STOP=1 "$@"; }

say "loading the extension and computing a vector"
psql_super -q -d postgres -c "CREATE DATABASE ${VERIFY_DB}" || abort "could not create the verification database"
psql_super -q -d "$VERIFY_DB" -c "CREATE EXTENSION vector" || abort "the built extension does not load"
psql_super -q -d "$VERIFY_DB" -c "CREATE TABLE v (id serial primary key, e vector(3))" || abort "could not create the vector column"
psql_super -q -d "$VERIFY_DB" -c "INSERT INTO v (e) VALUES ('[1,0,0]')" || abort "could not insert a vector"
DIST="$(psql_super -q -t -A -d "$VERIFY_DB" -c "SELECT round((e <=> '[1,0,0]')::numeric, 6) FROM v LIMIT 1")"
# The comparison is NUMERIC, not textual: the value arrives as "0.000000" (the
# rounded numeric), and a string comparison against "0" would fail a check
# whose subject is in fact correct.
if ! awk -v d="${DIST:-x}" 'BEGIN { exit !(d + 0 == 0) }'; then
	abort "the vector distance came back as '${DIST}', want 0"
fi
say "the built extension loads and computes"

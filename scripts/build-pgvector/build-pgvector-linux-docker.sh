#!/usr/bin/env bash
#
# build-pgvector-linux-docker.sh — run the pgvector build inside a container.
#
# The recipe (build-pgvector-linux.sh) needs a PostgreSQL 17 development
# toolchain, which a developer machine may not have. This wrapper runs the
# SAME recipe in a throwaway container, so the artifact a developer produces
# locally is the artifact CI produces.
#
# Usage: scripts/build-pgvector/build-pgvector-linux-docker.sh [out-dir]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$HERE/out}"

docker run --rm \
	-v "$HERE:/work" \
	-v "$OUT_DIR:/work/out" \
	-e OUT_DIR=/work/out \
	-e PGVECTOR_VERSION="${PGVECTOR_VERSION:-v0.8.6}" \
	ubuntu:24.04 \
	bash -c '
		set -euo pipefail
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq
		# The base build tools FIRST: the PostgreSQL packages are not in the
		# distribution archive, so the PGDG repository has to be added before
		# any postgresql package is asked for (installing them first fails with
		# "Unable to locate package postgresql-17").
		apt-get install -y -qq --no-install-recommends \
			build-essential ca-certificates git curl gnupg
		install -d /usr/share/postgresql-common/pgdg
		curl -sS -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
			https://www.postgresql.org/media/keys/ACCC4CF8.asc
		echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
			> /etc/apt/sources.list.d/pgdg.list
		apt-get update -qq
		apt-get install -y -qq --no-install-recommends \
			postgresql-17 postgresql-client-17 postgresql-server-dev-17
		bash /work/build-pgvector-linux.sh
	'

echo "build-pgvector: the packaged extension is in $OUT_DIR"

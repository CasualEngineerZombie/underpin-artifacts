#!/usr/bin/env bash
#
# build-bundle-docker.sh — run the portable PostgreSQL + pgvector bundle build
# inside a container.
#
# The recipe needs a PostgreSQL build toolchain (autoconf, make, a C compiler,
# bison and flex), which a developer machine may not have. This wrapper runs
# the SAME recipe in a throwaway container, so the artifact a developer
# produces locally is the artifact CI produces.
#
# Usage: scripts/build-postgres-pgvector/build-bundle-docker.sh [out-dir]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$HERE/out}"

docker run --rm \
	-v "$HERE:/work" \
	-v "$OUT_DIR:/work/out" \
	-e OUT_DIR=/work/out \
	-e PG_VERSION="${PG_VERSION:-17.6}" \
	-e PG_SHA256="${PG_SHA256:-e0630a3600aea27511715563259ec2111cd5f4353a4b040e0be827f94cd7a8b0}" \
	-e PGVECTOR_VERSION="${PGVECTOR_VERSION:-v0.8.6}" \
	-e PREFIX=/opt/pgsql \
	-e SRC_DIR=/work/src \
	ubuntu:24.04 \
	bash -c '
		set -euo pipefail
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq
		# The build toolchain: PostgreSQL needs a C compiler, make and the
		# parser generators; patchelf rewrites the runtime search path so the
		# packaged tree is relocatable.
		apt-get install -y -qq --no-install-recommends \
			build-essential bison flex ca-certificates git curl \
			bzip2 patchelf
		# The build writes into /opt/pgsql (root is fine for the BUILD), and
		# the verification runs as an unprivileged user because PostgreSQL
		# refuses to run as root.
		mkdir -p /opt/pgsql
		bash /work/build-bundle.sh
	'

echo "build-bundle: the packaged bundle is in $OUT_DIR"

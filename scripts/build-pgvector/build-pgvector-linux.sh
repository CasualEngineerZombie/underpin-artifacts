#!/usr/bin/env bash
#
# build-pgvector-linux.sh — build pgvector FROM SOURCE and package it as a
# relocatable extension tree.
#
# WHY. The desktop install needs a pgvector build for the PostgreSQL it
# provisions. Upstream pgvector publishes no Windows binaries (building it
# needs the MSVC toolchain), so the Windows artifact has historically come
# from a third-party community build. This script builds it ourselves, from a
# pinned upstream tag, in our own CI — which removes the third-party binary
# from the install's trust boundary.
#
# The output is the SAME layout a package manager installs:
#
#     lib/vector.so            (or vector.dylib on macOS, vector.dll on Windows)
#     share/extension/vector.control
#     share/extension/vector*.sql
#
# so the injector's shape is identical for every platform.
#
# The build is VERIFIED before it is packaged: the extension is loaded into a
# scratch database and a vector is computed through it. A build that compiles
# but does not load is worse than no build — the install would provision a
# cluster whose vector extension silently refuses to activate, and the first
# embedding insert would fail with a message that points at the embedding code
# rather than at the extension.
#
# PRIVILEGES. The install step writes into the PostgreSQL installation's lib/
# and share/ directories, so it needs root (or sudo). The verification starts a
# PostgreSQL server, and PostgreSQL REFUSES to run as root — so the two halves
# run at different levels: the install at the privileged one, the verification
# at the unprivileged one (see verify-pgvector.sh).
#
# Environment:
#   PG_CONFIG        the pg_config to build against (default: pg_config on PATH)
#   PGVECTOR_VERSION the upstream tag to build (default: v0.8.6)
#   OUT_DIR          where the packaged tree is written (default: out)
#   SRC_DIR          where the source is checked out (default: src)

set -euo pipefail

PGVECTOR_VERSION="${PGVECTOR_VERSION:-v0.8.6}"
OUT_DIR="${OUT_DIR:-out}"
SRC_DIR="${SRC_DIR:-src}"
PG_CONFIG="${PG_CONFIG:-pg_config}"

say() { printf '==> %s\n' "$*"; }
abort() { printf 'build-pgvector: ABORT: %s\n' "$*" >&2; exit 1; }

command -v "$PG_CONFIG" >/dev/null 2>&1 || abort "$PG_CONFIG not found - install the PostgreSQL server development package"

# The source dir is made UNIQUE per run: a checkout left behind by an earlier
# run at a different privilege level is not removable by the current one, and
# reconciling that is not worth a special case.
rm -rf "$SRC_DIR" 2>/dev/null || true
mkdir -p "$SRC_DIR" 2>/dev/null || true
SRC_DIR="$(mktemp -d)"
chmod 0777 "$SRC_DIR" 2>/dev/null || true

say "building pgvector $PGVECTOR_VERSION against $("$PG_CONFIG" --version)"

git clone --depth 1 --branch "$PGVECTOR_VERSION" https://github.com/pgvector/pgvector.git "$SRC_DIR/pgvector" \
	|| abort "could not check out pgvector $PGVECTOR_VERSION"

make -C "$SRC_DIR/pgvector" PG_CONFIG="$PG_CONFIG" \
	|| abort "the pgvector build failed"

# The install step writes into the PostgreSQL installation, so it needs root
# (or sudo) - the developer's own account cannot write there.
if [ "$(id -u)" = "0" ]; then
	make -C "$SRC_DIR/pgvector" install PG_CONFIG="$PG_CONFIG" \
		|| abort "the pgvector install step failed"
else
	sudo make -C "$SRC_DIR/pgvector" install PG_CONFIG="$PG_CONFIG" \
		|| abort "the pgvector install step failed"
fi

# --- verify: the extension must LOAD and compute, not merely compile ---
say "verifying the built extension"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(id -u)" = "0" ]; then
	chmod 0755 "$HERE/verify-pgvector.sh" 2>/dev/null || true
	su postgres -s /bin/bash -c "PG_CONFIG='$PG_CONFIG' bash '$HERE/verify-pgvector.sh'" \
		|| abort "the verification failed - the built extension does not load and compute"
else
	PG_CONFIG="$PG_CONFIG" bash "$HERE/verify-pgvector.sh" \
		|| abort "the verification failed - the built extension does not load and compute"
fi

# --- package: the layout a package manager installs ---
PKGLIBDIR="$("$PG_CONFIG" --pkglibdir)"
SHAREDIR="$("$PG_CONFIG" --sharedir)"

# The output dir may be a MOUNT POINT (the container mounts it from the host),
# so the directory itself cannot be removed - only its contents.
mkdir -p "$OUT_DIR" 2>/dev/null || true
find "$OUT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
mkdir -p "$OUT_DIR/lib" "$OUT_DIR/share/extension"

if [ -f "$PKGLIBDIR/vector.so" ]; then
	cp "$PKGLIBDIR/vector.so" "$OUT_DIR/lib/"
elif [ -f "$PKGLIBDIR/vector.dylib" ]; then
	cp "$PKGLIBDIR/vector.dylib" "$OUT_DIR/lib/"
else
	abort "the built library is not in $PKGLIBDIR"
fi
cp "$SHAREDIR"/extension/vector.control "$OUT_DIR/share/extension/"
cp "$SHAREDIR"/extension/vector*.sql "$OUT_DIR/share/extension/"

say "packaged the extension into $OUT_DIR"
find "$OUT_DIR" -type f | sort

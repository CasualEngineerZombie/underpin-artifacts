#!/usr/bin/env bash
#
# build-bundle.sh — build a PORTABLE PostgreSQL + pgvector bundle from source.
#
# WHY THIS EXISTS. The desktop install provisions the user's machine from the
# network on first run, so every byte it downloads is code that then runs with
# the user's privileges. Upstream PostgreSQL publishes no portable binaries for
# Linux or macOS (the distribution packages need root, and EDB publishes the
# "binaries without installer" archive for Windows only), and upstream
# pgvector publishes no binaries at all.
#
# So this builds BOTH, from pinned upstream sources, and packages them as one
# artifact:
#
#     bin/    initdb, pg_ctl, postgres, pg_dump, pg_restore, psql, ...
#     lib/    the server's modules AND the pgvector extension (vector.so)
#     share/  the server's data files AND the extension's SQL/control files
#
# ONE artifact, ONE digest, and the extension is built against the exact
# server it ships with — so the extension ABI question cannot even be asked.
#
# THE VERIFY STEP IS NOT OPTIONAL. The bundle is packaged only after the
# built server has been started for real, the extension loaded, a vector
# computed through it, and a pg_dump/pg_restore round trip completed. A build
# that compiles but does not load is worse than no build: the install would
# provision a cluster whose vector extension silently refuses to activate, and
# the first embedding insert would fail with a message that points at the
# embedding code rather than at the extension.
#
# RELOCATABILITY. The bundle is installed into a directory the user chose, not
# into the prefix it was built in, so the shipped binaries must not carry the
# build-time prefix in their runtime search path. The packaging step rewrites
# it to $ORIGIN/../lib (Linux) or @loader_path/../lib (macOS).
#
# PRIVILEGES. PostgreSQL REFUSES to run as root ("initdb: cannot be run as
# root"), so the verification runs as an unprivileged user even when the build
# itself ran as root.
#
# Environment:
#   PG_VERSION        the PostgreSQL version to build (default: 17.6)
#   PG_SHA256         the expected sha256 of the source tarball
#   PGVECTOR_VERSION  the upstream pgvector tag to build (default: v0.8.6)
#   PREFIX            where PostgreSQL is installed (default: ./build/pgsql)
#   OUT_DIR           where the packaged tree is written (default: out)
#   SRC_DIR           where the sources are checked out (default: ./src)
#   JOBS              parallel build jobs (default: the machine's CPU count)

set -euo pipefail

PG_VERSION="${PG_VERSION:-17.6}"
PG_SHA256="${PG_SHA256:-e0630a3600aea27511715563259ec2111cd5f4353a4b040e0be827f94cd7a8b0}"
PGVECTOR_VERSION="${PGVECTOR_VERSION:-v0.8.6}"

# ANCHOR EVERY PATH BEFORE THE BUILD CHANGES DIRECTORY. The build cd's into the
# PostgreSQL source tree (step 2) and never comes back, so a RELATIVE path is
# resolved against that tree rather than against the directory the caller ran
# the script in. That bug shipped once: CI passed OUT_DIR=out, the bundle was
# written into src/postgresql-17.6/out, and the upload step -- which looked for
# out/ at the workspace root -- found nothing, so the build "succeeded" and
# produced no artifact. Resolving to absolute here makes the values mean the
# caller's directory no matter how many times the script cd's.
INVOCATION_DIR="$PWD"
PREFIX="${PREFIX:-$INVOCATION_DIR/build/pgsql}"
OUT_DIR="${OUT_DIR:-out}"
SRC_DIR="${SRC_DIR:-$INVOCATION_DIR/src}"
case "$PREFIX" in /*) ;; *) PREFIX="$INVOCATION_DIR/$PREFIX" ;; esac
case "$OUT_DIR" in /*) ;; *) OUT_DIR="$INVOCATION_DIR/$OUT_DIR" ;; esac
case "$SRC_DIR" in /*) ;; *) SRC_DIR="$INVOCATION_DIR/$SRC_DIR" ;; esac

# nproc is Linux; macOS has sysctl. The fallback keeps a single-core machine
# working rather than failing the build.
detect_jobs() {
	if command -v nproc >/dev/null 2>&1; then
		nproc
	elif command -v sysctl >/dev/null 2>&1; then
		sysctl -n hw.ncpu
	else
		echo 2
	fi
}
JOBS="${JOBS:-$(detect_jobs)}"

say() { printf '==> %s\n' "$*"; }
abort() { printf 'build-bundle: ABORT: %s\n' "$*" >&2; exit 1; }

# SCRIPT_PATH is this script's ABSOLUTE path. The verification is a separate
# entry point, and the script CHANGES DIRECTORY during the build (into the
# PostgreSQL source tree), so a relative "$0" would no longer resolve when the
# verification re-enters the script.
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------------------
# run_verification — start the built server, load the extension, compute a vector, and
# round-trip a dump through the bundled client tools.
#
# It runs as an UNPRIVILEGED user (PostgreSQL refuses to run as root), and it is a
# separate entry point so the build can invoke it under `su` without re-running the
# build itself.
# ---------------------------------------------------------------------------------------
run_verification() {
	set -euo pipefail
	PG_CONFIG="${PG_CONFIG:-$PREFIX/bin/pg_config}"
	[ -x "$PG_CONFIG" ] || abort "pg_config is missing from $PREFIX/bin"
	PGBIN="$("$PG_CONFIG" --bindir)"
	PGDATA="${VERIFY_DIR:?}/data"
	SOCKDIR="${VERIFY_DIR:?}/sock"
	VERIFY_PORT="${VERIFY_PORT:-55434}"
	VERIFY_DB="bundle_verify_$$"

	cleanup() {
		"$PGBIN/pg_ctl" -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
	}
	trap cleanup EXIT

	say "initialising a scratch cluster"
	"$PGBIN/initdb" -D "$PGDATA" -U postgres --no-locale >/dev/null 2>&1 \
		|| abort "could not initialise the verification cluster"

	# The socket directory has to EXIST before the server is asked to listen
	# in it: PostgreSQL creates the socket FILE, not the directory, and a
	# missing directory fails the start with "could not create lock file".
	mkdir -p "$SOCKDIR"

	say "starting the scratch server"
	if ! "$PGBIN/pg_ctl" -D "$PGDATA" -o "-k $SOCKDIR -p $VERIFY_PORT -h ''" -w -l "$PGDATA/server.log" start >/dev/null 2>&1; then
		say "the server log follows"
		cat "$PGDATA/server.log" 2>/dev/null || true
		abort "could not start the verification server"
	fi

	psql_super() { "$PGBIN/psql" -h "$SOCKDIR" -p "$VERIFY_PORT" -U postgres -v ON_ERROR_STOP=1 "$@"; }

	say "loading the extension and computing a vector"
	psql_super -q -d postgres -c "CREATE DATABASE ${VERIFY_DB}" || abort "could not create the verification database"
	psql_super -q -d "$VERIFY_DB" -c "CREATE EXTENSION vector" || abort "the built extension does not load"
	psql_super -q -d "$VERIFY_DB" -c "CREATE TABLE v (id serial primary key, e vector(3))" || abort "could not create the vector column"
	psql_super -q -d "$VERIFY_DB" -c "INSERT INTO v (e) VALUES ('[1,0,0]')" || abort "could not insert a vector"
	DIST="$(psql_super -q -t -A -d "$VERIFY_DB" -c "SELECT round((e <=> '[1,0,0]')::numeric, 6) FROM v LIMIT 1")"
	# The comparison is NUMERIC, not textual: the value arrives as "0.000000",
	# and a string comparison against "0" would fail a check whose subject is
	# in fact correct.
	if ! awk -v d="${DIST:-x}" 'BEGIN { exit !(d + 0 == 0) }'; then
		abort "the vector distance came back as '${DIST}', want 0"
	fi
	say "the built extension loads and computes"

	# The client tools are part of the bundle, so they are verified HERE too:
	# a bundle without a working pg_dump is a bundle whose backup path is
	# broken, and the desktop install would not find out until a user tried to
	# back up.
	say "verifying the client tools (pg_dump / pg_restore round trip)"
	psql_super -q -d "$VERIFY_DB" -c "CREATE TABLE rt (id serial primary key, note text)" || abort "could not create the round-trip table"
	psql_super -q -d "$VERIFY_DB" -c "INSERT INTO rt (note) VALUES ('round-trip marker')" || abort "could not insert the round-trip row"
	"$PGBIN/pg_dump" --format=custom --no-owner --no-privileges --file="$VERIFY_DIR/rt.dump" \
		-h "$SOCKDIR" -p "$VERIFY_PORT" -U postgres -d "$VERIFY_DB" || abort "pg_dump failed"
	"$PGBIN/pg_restore" --no-owner --no-privileges --clean --if-exists \
		-h "$SOCKDIR" -p "$VERIFY_PORT" -U postgres -d "$VERIFY_DB" "$VERIFY_DIR/rt.dump" >/dev/null 2>&1 \
		|| abort "pg_restore failed"
	COUNT="$(psql_super -q -t -A -d "$VERIFY_DB" -c "SELECT count(*) FROM rt WHERE note = 'round-trip marker'")"
	if [ "${COUNT:-0}" != "1" ]; then
		abort "the pg_dump/pg_restore round trip lost the row (count=${COUNT:-none})"
	fi
	say "the client tools round-trip"
	say "the built bundle is verified"
}

# The verification entry point. It is dispatched BEFORE anything else so that
# invoking the script with --verify-only runs the verification and NOTHING
# else — the build calls it under `su`, and re-running the build there would
# be both wrong and infinitely recursive.
if [ "${1:-}" = "--verify-only" ]; then
	run_verification
	exit 0
fi

# --- 1. the PostgreSQL source, verified ------------------------------------------------
mkdir -p "$SRC_DIR"
TARBALL="postgresql-${PG_VERSION}.tar.bz2"
TARBALL_URL="https://ftp.postgresql.org/pub/source/v${PG_VERSION}/${TARBALL}"
TARBALL_PATH="$SRC_DIR/$TARBALL"

say "fetching $TARBALL_URL"
if command -v curl >/dev/null 2>&1; then
	# --retry: the mirror occasionally drops a connection mid-transfer, and a
	# build that fails on a network blip is indistinguishable from a build
	# that fails on a real problem.
	curl -fSL --retry 5 --retry-delay 2 --retry-connrefused -o "$TARBALL_PATH" "$TARBALL_URL" \
		|| abort "could not download $TARBALL_URL"
elif command -v wget >/dev/null 2>&1; then
	wget -q -O "$TARBALL_PATH" "$TARBALL_URL" || abort "could not download $TARBALL_URL"
else
	abort "neither curl nor wget is available"
fi

say "verifying the source tarball's sha256"
if command -v sha256sum >/dev/null 2>&1; then
	GOT_SHA="$(sha256sum "$TARBALL_PATH" | awk '{print $1}')"
else
	GOT_SHA="$(shasum -a 256 "$TARBALL_PATH" | awk '{print $1}')"
fi
if [ "$GOT_SHA" != "$PG_SHA256" ]; then
	abort "the tarball's sha256 is $GOT_SHA, want $PG_SHA256 (the download was discarded)"
fi
say "sha256 verified: $GOT_SHA"

# --- 2. build and install PostgreSQL ---------------------------------------------------
rm -rf "$SRC_DIR/postgresql-${PG_VERSION}"
tar -xjf "$TARBALL_PATH" -C "$SRC_DIR" || abort "could not unpack $TARBALL"

say "configuring PostgreSQL $PG_VERSION into $PREFIX"
# --without-icu: ICU is a heavy runtime dependency and the desktop cluster is
#   initialised with --no-locale, so the locale-aware collations buy nothing.
# --without-readline: psql's line editing needs libreadline, whose SONAME
#   differs across the macOS releases; a bundle that links it is a bundle that
#   fails to start on a machine with a different one.
# --without-zlib: same reason (and pg_dump -Fc simply writes uncompressed
#   blocks, which the restore leg reads back without trouble).
# --without-openssl: the desktop cluster listens on loopback only and is never
#   exposed, so TLS would add a runtime dependency for nothing.
cd "$SRC_DIR/postgresql-${PG_VERSION}"
if [ -x "$PREFIX/bin/pg_config" ] && \
	[ "$("$PREFIX/bin/pg_config" --version | awk '{print $3}')" = "$PG_VERSION" ]; then
	# The prefix already carries this exact version, so the build is skipped.
	# A build that can be re-run cheaply is a build that gets re-run when a
	# later step fails, and that is what turns a one-line fix into a
	# ten-minute wait.
	say "the prefix already carries PostgreSQL $PG_VERSION, skipping the build"
else
	./configure --prefix="$PREFIX" \
		--without-icu --without-readline --without-zlib \
		--without-openssl \
		>"$SRC_DIR/configure.log" 2>&1 || abort "configure failed — see $SRC_DIR/configure.log"

	say "building PostgreSQL ($JOBS jobs)"
	make -j"$JOBS" >"$SRC_DIR/make.log" 2>&1 || abort "the build failed — see $SRC_DIR/make.log"
	say "installing PostgreSQL into $PREFIX"
	make install >"$SRC_DIR/install.log" 2>&1 || abort "the install step failed — see $SRC_DIR/install.log"
fi

PG_CONFIG="$PREFIX/bin/pg_config"
[ -x "$PG_CONFIG" ] || abort "pg_config is missing from $PREFIX/bin after the install"
say "built PostgreSQL $("$PG_CONFIG" --version)"

# --- 3. build pgvector AGAINST that server -------------------------------------------
say "building pgvector $PGVECTOR_VERSION against $("$PG_CONFIG" --version)"
rm -rf "$SRC_DIR/pgvector"
git clone --depth 1 --branch "$PGVECTOR_VERSION" https://github.com/pgvector/pgvector.git "$SRC_DIR/pgvector" \
	|| abort "could not check out pgvector $PGVECTOR_VERSION"
make -C "$SRC_DIR/pgvector" PG_CONFIG="$PG_CONFIG" >"$SRC_DIR/pgvector-make.log" 2>&1 \
	|| abort "the pgvector build failed — see $SRC_DIR/pgvector-make.log"
make -C "$SRC_DIR/pgvector" install PG_CONFIG="$PG_CONFIG" >"$SRC_DIR/pgvector-install.log" 2>&1 \
	|| abort "the pgvector install step failed — see $SRC_DIR/pgvector-install.log"

# The extension's shared library must be IN the tree we ship, not beside it.
if [ "$(uname -s)" = "Darwin" ]; then
	VEC_EXT="dylib"
else
	VEC_EXT="so"
fi
VEC_LIB="$("$PG_CONFIG" --pkglibdir)/vector.${VEC_EXT}"
[ -f "$VEC_LIB" ] || abort "the built pgvector library is not at $VEC_LIB"
say "built pgvector: $VEC_LIB"

# --- 4. verify: the server starts, the extension loads, a vector computes ------------
say "verifying the bundle"
VERIFY_USER="postgres"
if [ "$(id -u)" = "0" ]; then
	# PostgreSQL refuses to run as root, so the verification runs as an
	# unprivileged user. The build itself ran as root (it needs to write into
	# the prefix), so the two halves run at different levels.
	id -u "$VERIFY_USER" >/dev/null 2>&1 || useradd -m "$VERIFY_USER"
	chmod -R a+rX "$PREFIX"
	chmod a+x "$PREFIX/bin"
	VERIFY_DIR="$(mktemp -d)"
	chmod 0777 "$VERIFY_DIR"
	su "$VERIFY_USER" -s /bin/bash -c "VERIFY_DIR='$VERIFY_DIR' PREFIX='$PREFIX' PG_CONFIG='$PG_CONFIG' bash '$SCRIPT_PATH' --verify-only" \
		|| abort "the verification failed — the built server does not run, or the extension does not load"
else
	VERIFY_DIR="$(mktemp -d)"
	VERIFY_DIR="$VERIFY_DIR" PG_CONFIG="$PG_CONFIG" bash "$SCRIPT_PATH" --verify-only \
		|| abort "the verification failed — the built server does not run, or the extension does not load"
fi

# --- 5. package: the layout the install expects ---------------------------------------
say "packaging the bundle into $OUT_DIR"
mkdir -p "$OUT_DIR"
find "$OUT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
mkdir -p "$OUT_DIR/bin" "$OUT_DIR/lib" "$OUT_DIR/share"

# bin/: the server and the CLIENT TOOLS. The client tools are not optional:
# `underpin backup` shells out to pg_dump, and without it the desktop install
# has no way to take a backup.
cp -a "$PREFIX"/bin/. "$OUT_DIR/bin/"

# lib/: the server's modules and the pgvector extension.
cp -a "$("$PG_CONFIG" --pkglibdir)"/. "$OUT_DIR/lib/"

# share/: the server's data files and the extension's SQL/control files.
cp -a "$("$PG_CONFIG" --sharedir)"/. "$OUT_DIR/share/"

# The headers, the static libraries and the JIT bitcode are BUILD artifacts:
# they are large, they are not needed to run a server, and nothing in the
# install reads them.
rm -rf "$OUT_DIR/include" "$OUT_DIR/lib/pkgconfig" "$OUT_DIR/lib/bitcode" 2>/dev/null || true
find "$OUT_DIR" -name '*.a' -delete 2>/dev/null || true

# --- 6. make the tree RELOCATABLE -----------------------------------------------------
# The binaries were linked against the BUILD-TIME prefix. The install unpacks
# them into a directory the user chose, so the build-time path must be
# rewritten to point at the tree's own lib/ directory.
say "rewriting the runtime search path so the tree is relocatable"
if [ "$(uname -s)" = "Darwin" ]; then
	command -v install_name_tool >/dev/null 2>&1 || abort "install_name_tool is missing (macOS ships it in the command line tools)"
	for f in "$OUT_DIR"/bin/* "$OUT_DIR"/lib/*.dylib; do
		[ -f "$f" ] || continue
		# The install names that point INTO the build prefix become
		# @loader_path/../lib, which is the tree's own lib/ directory
		# whatever directory the tree ends up in.
		install_name_tool -change "$PREFIX/lib/libpq.5.dylib" "@loader_path/../lib/libpq.5.dylib" "$f" 2>/dev/null || true
		install_name_tool -id "@loader_path/../lib/$(basename "$f")" "$f" 2>/dev/null || true
	done
else
	if command -v patchelf >/dev/null 2>&1; then
		for f in "$OUT_DIR"/bin/* "$OUT_DIR"/lib/*.so; do
			[ -f "$f" ] || continue
			# $ORIGIN is the directory of the binary itself, so ../lib is
			# the tree's lib/ directory relative to it.
			patchelf --set-rpath '$ORIGIN/../lib' "$f" 2>/dev/null || true
		done
		say "the runtime search path is now relative to the tree"
	else
		# patchelf is missing: the tree still WORKS as long as it is left
		# where it was built, but it would not be relocatable. This is
		# reported rather than silently shipped.
		say "WARNING: patchelf is not installed, so the tree keeps the build-time library path"
	fi
fi

say "packaged the bundle into $OUT_DIR"

# A tree that exists but is missing the binaries the install runs is not a
# bundle. This is the LAST cheap check before packaging is declared done: a
# relative OUT_DIR once landed in the source tree and the upload found nothing,
# so the tree's completeness is asserted here as well as by the upload step.
for required in bin/postgres bin/initdb bin/pg_ctl bin/psql bin/pg_dump bin/pg_restore; do
	[ -x "$OUT_DIR/$required" ] || abort "the packaged tree is missing $required"
done
[ -f "$OUT_DIR/lib/vector.${VEC_EXT}" ] || abort "the packaged tree is missing the pgvector extension"

du -sh "$OUT_DIR"
find "$OUT_DIR" -type f | wc -l | sed 's/^/files: /'

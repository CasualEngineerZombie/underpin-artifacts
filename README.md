# Underpin OS — desktop install artifacts

This repository holds the **downloadable artifacts** for the Underpin OS desktop
install: the portable PostgreSQL + pgvector bundles a user's machine provisions
itself with.

It is a SEPARATE, PUBLIC repository on purpose. The install downloads these
files on the user's first run, so they have to be reachable **without
authentication** — and the product's own repository is private.

## What is in a bundle

One artifact per platform, holding:

```
bin/    initdb, pg_ctl, postgres, pg_dump, pg_restore, psql, ...
lib/    the server's modules AND the pgvector extension (vector.so)
share/  the server's data files AND the extension's SQL/control files
```

PostgreSQL is built **from source** (a pinned upstream tarball, sha256-verified)
and pgvector is built **against that exact server**, so the extension and the
server it loads into are one thing — the extension ABI question cannot be
asked.

The client tools are not optional: `underpin backup` shells out to `pg_dump`,
and a desktop install with no `pg_dump` has no way to take a backup.

## Releases

| Tag | Assets |
|---|---|
| `pgbundle-v1` | `postgres-pgvector-linux-amd64.zip` |

Each release also carries a `SHA256SUMS` file listing the digest of every
asset. The installer pins those digests in its manifest and checks them
**before** the bytes are used — a mismatch aborts the install, it never falls
back to "use it anyway".

## How a bundle is built

By this repository's own CI, from the recipe in `scripts/`:

- `scripts/build-postgres-pgvector/build-bundle.sh` — build PostgreSQL from
  source, build pgvector against it, verify, package.
- `scripts/build-postgres-pgvector/build-bundle-docker.sh` — run that recipe in
  a container, so a developer's machine needs no PostgreSQL toolchain.
- `scripts/build-pgvector/` — the extension-only build, used for the platforms
  whose PostgreSQL comes from a publisher (Windows).

## What is verified before an artifact is published

Not "it compiled". Every bundle is checked to:

1. **start** — the built server boots a scratch cluster;
2. **load and compute** — the extension is created and a vector distance is
   computed through it;
3. **round-trip** — `pg_dump` writes a `-Fc` archive and `pg_restore` puts the
   row back;
4. **survive relocation** — the packaged archive is unpacked somewhere *else*
   and does all of the above again. A bundle that only works in the directory
   it was built in is not a portable bundle, and the install unpacks it into a
   directory the user chose.

## Licence

PostgreSQL and pgvector are open source and carry their own licences (the
PostgreSQL Licence and the PostgreSQL Licence respectively). This repository
publishes builds of them; it does not relicense them.

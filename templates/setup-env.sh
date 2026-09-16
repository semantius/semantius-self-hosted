#!/usr/bin/env bash
# setup-env.sh  -  create .env from .env.example on first run, with UNIQUE secrets.
#
# This replaces the plain `cp .env.example .env` that create/up used to do. The
# copy is the same; what changes is that the three shipped DEV secrets are
# replaced with freshly generated ones before the file is written:
#
#   IDP_SECRET                        signs idp sessions, encrypts its JWT keys
#   POSTGRES_PASSWORD                 the `postgres` DBA login
#   SEMANTIUS_AUTHENTICATOR_PASSWORD  the login PostgREST uses
#
# WHY AT .env CREATION and not later: all three are load-bearing BEFORE first
# boot. IDP_SECRET encrypts the idp's stored signing keys, so changing it after
# the fact logs everyone out and makes those keys undecryptable; the two
# passwords are baked into the database by the image's first-init scripts, which
# run ONCE per data directory. Generating them here makes the secure state the
# DEFAULT state instead of a step nobody reads.
#
# IDEMPOTENT: an existing .env is never touched — no overwrite, no re-generation.
# Delete .env (or edit it) if you want different values.
#
# Usage:
#   ./setup-env.sh          create .env with generated secrets, or leave the existing one alone
set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then
  echo ".env already exists — leaving it untouched."
  exit 0
fi

[ -f .env.example ] || { echo "setup-env: .env.example is missing." >&2; exit 1; }

# URL-SAFE by construction: these two are spliced into connection URLs (the idp's
# DATABASE_URL, PostgREST's PGRST_DB_URI) and pgbouncer's entrypoint re-parses
# those with a naive grep/cut parser, so anything from `@ : / ? #` or a space
# breaks them. Hex avoids the lot — note `openssl rand -base64` does NOT: it
# emits `/` and `+`.
gen_urlsafe() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c 48 || true
  fi
}

# IDP_SECRET is never spliced into a URL — it is read straight from the
# environment — so the full base64 alphabet is fine, and 48 bytes clears the
# ">= 32 random bytes" the idp requires with room to spare.
gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -d '\n'
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 64 || true
  fi
}

idp_secret="$(gen_secret)"
pg_password="$(gen_urlsafe)"
auth_password="$(gen_urlsafe)"

# 32 chars is well short of what either generator produces; this only catches a
# box with neither openssl nor a readable /dev/urandom, where a SHORT or EMPTY
# secret would otherwise be written out and silently accepted.
for v in "$idp_secret" "$pg_password" "$auth_password"; do
  if [ "${#v}" -lt 32 ]; then
    echo "setup-env: could not generate a secret (no openssl, no usable /dev/urandom)." >&2
    echo "Install openssl, or copy .env.example to .env and set the three secrets by hand." >&2
    exit 1
  fi
done

# Written to a temp file and moved into place, so an interrupted run cannot leave
# a half-substituted .env behind — which would boot with a dev secret still in it.
# `|` as the sed delimiter: absent from both the hex and the base64 alphabet, as
# is `&` (which would otherwise expand to the match in the replacement).
tmp="$(mktemp .env.tmp.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

sed -e "s|^IDP_SECRET=.*|IDP_SECRET=${idp_secret}|" \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${pg_password}|" \
    -e "s|^SEMANTIUS_AUTHENTICATOR_PASSWORD=.*|SEMANTIUS_AUTHENTICATOR_PASSWORD=${auth_password}|" \
    .env.example > "$tmp"

# The substitutions are silent when a key is absent (a renamed variable, an
# .env.example edited to comment one out), which would ship a stack with no
# secret where the reader assumes a generated one. Fail instead.
for key in IDP_SECRET POSTGRES_PASSWORD SEMANTIUS_AUTHENTICATOR_PASSWORD; do
  if ! grep -qE "^${key}=.+" "$tmp"; then
    echo "setup-env: .env.example has no uncommented ${key}= line — nothing was generated for it." >&2
    exit 1
  fi
done

mv "$tmp" .env
trap - EXIT
chmod 600 .env 2>/dev/null || true

echo "Created .env from .env.example, with freshly generated secrets for"
echo "  IDP_SECRET, POSTGRES_PASSWORD and SEMANTIUS_AUTHENTICATOR_PASSWORD."
echo "They are in .env (gitignored) — that is the only copy. Read the DBA password with:"
echo "  grep '^POSTGRES_PASSWORD=' .env"

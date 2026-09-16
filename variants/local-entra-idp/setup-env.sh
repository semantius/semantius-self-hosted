#!/usr/bin/env bash
# setup-env.sh  -  create .env from .env.example on first run, with UNIQUE secrets.
#
# This replaces the plain `cp .env.example .env` that create/up used to do. The
# copy is the same; what changes is that the shipped DEV secrets are replaced
# with freshly generated ones before the file is written:
#
#   POSTGRES_PASSWORD                 the `postgres` DBA login
#   SEMANTIUS_AUTHENTICATOR_PASSWORD  the login PostgREST uses
#
# WHY AT .env CREATION and not later: they are load-bearing BEFORE first boot.
# The two passwords are baked into the database by the image's first-init
# scripts, which run ONCE per data directory.
# Generating them here makes the secure state the DEFAULT state instead of a
# step nobody reads.
#
# IDEMPOTENT: an existing .env is never touched — no overwrite, no re-generation.
# Delete .env (or edit it) if you want different values.
#
# Usage:
#   ./setup-env.sh          create .env with generated secrets, or leave the existing one alone
set -euo pipefail
cd "$(dirname "$0")"

# An EXISTING .env is repaired, not replaced: every value the operator put there
# survives, and only the generated secrets below are looked at. A secret counts
# as needing one when it is missing, empty, or still the value .env.example
# ships — the last case is what catches the `cp .env.example .env` that leaves a
# stack running on a published password.
REPAIR=0
if [ -f .env ]; then
  REPAIR=1
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

pg_password="$(gen_urlsafe)"
auth_password="$(gen_urlsafe)"

# ONE list of `KEY=value` entries, so a key can never drift apart from the value
# generated for it. A variant build cuts a feature's entries out of it, and
# nothing is then generated, checked or reported for a variable that variant's
# .env.example does not have.
GENERATED=(
  "POSTGRES_PASSWORD=${pg_password}"
  "SEMANTIUS_AUTHENTICATOR_PASSWORD=${auth_password}"
)

# 32 chars is well short of what either generator produces; this only catches a
# box with neither openssl nor a readable /dev/urandom, where a SHORT or EMPTY
# secret would otherwise be written out and silently accepted.
for entry in "${GENERATED[@]}"; do
  if [ "${#entry}" -lt 40 ]; then
    echo "setup-env: could not generate a secret (no openssl, no usable /dev/urandom)." >&2
    echo "Install openssl, or copy .env.example to .env and set the secrets by hand." >&2
    exit 1
  fi
done

# Written to a temp file and moved into place, so an interrupted run cannot leave
# a half-substituted .env behind — which would boot with a dev secret still in it.
tmp="$(mktemp .env.tmp.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

if [ "$REPAIR" = 1 ]; then cp .env "$tmp"; else cp .env.example "$tmp"; fi

# `|` as the sed delimiter: absent from both the hex and the base64 alphabet, as
# is `&`, which would otherwise expand to the match in the replacement.
written=""
for entry in "${GENERATED[@]}"; do
  key="${entry%%=*}"
  value="${entry#*=}"

  if [ "$REPAIR" = 1 ]; then
    current="$(grep -E "^${key}=" "$tmp" | tail -1 | cut -d= -f2- | tr -d '')"
    shipped="$(grep -E "^${key}=" .env.example | tail -1 | cut -d= -f2- | tr -d '')"
    # Yours already, and not the value .env.example publishes — leave it alone.
    if [ -n "$current" ] && [ "$current" != "$shipped" ]; then
      continue
    fi
  fi

  if grep -qE "^${key}=" "$tmp"; then
    sed -e "s|^${key}=.*|${key}=${value}|" "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
  else
    # Absent entirely (a hand-trimmed .env): append rather than silently skip.
    printf '%s
' "${key}=${value}" >> "$tmp"
  fi
  written="$written ${key}"
done

if [ "$REPAIR" = 1 ] && [ -z "$written" ]; then
  echo ".env already holds a real value for every generated secret — nothing to do."
  exit 0
fi

# The substitutions are silent when a key is absent from a FRESH copy, which
# would ship a stack with no secret where the reader assumes a generated one.
if [ "$REPAIR" != 1 ]; then
  for entry in "${GENERATED[@]}"; do
    key="${entry%%=*}"
    if ! grep -qE "^${key}=.+" "$tmp"; then
      echo "setup-env: nothing was generated for ${key}." >&2
      exit 1
    fi
  done
fi

mv "$tmp" .env
trap - EXIT
chmod 600 .env 2>/dev/null || true

if [ "$REPAIR" = 1 ]; then
  echo "Repaired .env — generated a fresh value for:${written}"
  echo "Everything else in the file was left exactly as it was."
else
  echo "Created .env from .env.example, with freshly generated secrets for"
  echo " ${written}."
fi
echo "They are in .env (gitignored) — that is the only copy. Read the DBA password with:"
echo "  grep '^POSTGRES_PASSWORD=' .env"

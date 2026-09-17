#!/usr/bin/env bash
# up.sh  -  (re)create the stack's CONTAINERS from the current compose config and
# start them, KEEPING the database.
#
# This is `docker compose up --force-recreate`. Reach for it after changing
# docker-compose.yml, .env or the Caddyfile: the containers are replaced, your
# data survives.
#
# It does NOT give you a clean database. The image's first-init scripts
# (CREATE EXTENSION, the authenticator LOGIN, anon, the optional NWIND load) run
# ONCE per data directory, so an existing pgdata volume keeps the OLD schema no
# matter how many times the containers are recreated. For a fresh database — and
# for any honest test of an image — use ./create.sh, which wipes the volume first.
#
# EVERY IMAGE COMES FROM A REGISTRY. Nothing here is built from source, so this
# works in a fresh clone with no toolchain installed.
#
# Usage:
#   ./up.sh                  pull the published DB image, then up
#   ./up.sh 0.4.0-pg18       ... pinned to that tag (overrides SEMANTIUS_DB_VERSION)
#   ./up.sh --no-pull        skip the DB pull and run whatever image is already
#                            tagged locally (for testing an image you built
#                            yourself — see the semantius repo's docker-postgres/)
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '/^# Usage:/,/docker-postgres/p' "$0" | sed 's/^# \{0,1\}//'; }

PULL=1; DB_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-pull) PULL=0 ;;
    --pull)    PULL=1 ;;   # the default; accepted so it can be stated explicitly
    -h|--help) usage; exit 0 ;;
    -*)        echo "Unknown option: $1" >&2; echo >&2; usage >&2; exit 1 ;;
    *)         DB_VERSION="$1" ;;   # a bare argument is the image tag
  esac
  shift
done

# A tag selects a PUBLISHED image, which only a pull can fetch — the two cannot be
# combined without lying about what is running.
if [ "$PULL" = 0 ] && [ -n "$DB_VERSION" ]; then
  echo "A version tag ('$DB_VERSION') applies only when pulling — --no-pull runs whatever is tagged locally." >&2
  exit 1
fi

# CONFIGURATION IS NOT THIS SCRIPT'S JOB. It runs docker; ./setup-env.sh writes
# .env. Creating one here would mean a command called "create the containers"
# quietly deciding your passwords — and, in a variant configured against an
# external identity provider or database, producing a file that still lacks
# every value that matters.
if [ ! -f .env ]; then
  echo "No .env in $(pwd)." >&2
  echo >&2
  echo "  ./setup-env.sh    creates it from .env.example, with generated secrets" >&2
  echo >&2
  echo "Then fill in anything the README marks as required, and run this again." >&2
  exit 1
fi

# Values this stack cannot start without are written `${VAR:?...}` in the compose
# file, so they can be read straight out of it — no list to keep in step. Without
# this, a missing value surfaces as a wall of compose interpolation errors.
missing=""
for var in $(grep -oE '\$\{[A-Z_][A-Z0-9_]*:\?' docker-compose.yml | sed 's/^\${//; s/:?$//' | sort -u); do
  value="$(grep -E "^${var}=" .env | tail -1 | cut -d= -f2- | tr -d '')"
  if [ -z "$value" ]; then missing="$missing $var"; fi
done
if [ -n "$missing" ]; then
  echo "This stack needs values in .env before it can start:" >&2
  for var in $missing; do echo "  $var" >&2; done
  echo >&2
  echo "See README.md in this folder." >&2
  exit 1
fi

# An explicit tag wins over .env: the shell environment takes precedence over the
# .env file in docker compose's variable resolution.
if [ -n "$DB_VERSION" ]; then
  export SEMANTIUS_DB_VERSION="$DB_VERSION"
  echo "Pinning SEMANTIUS_DB_VERSION=${DB_VERSION} for this run."
fi

# Read ONE value out of .env. NOT `. ./.env`: .env is a compose file, not a
# shell script, and a value with spaces or braces is not shell syntax. The
# external-idp variant has both as a matter of course — VITE_OAUTH_SCOPE is
# `openid profile email offline_access api://…/access_as_user` and
# VITE_UI_CUSTOMIZER is a JSON menu — so sourcing it made bash try to run
# `profile` as a command and, under `set -e`, kill this script with exit 127
# AFTER the stack was already up: a create/up that had in fact worked then
# reported failure and printed no summary. grep reads it the way compose does.
envval() { { grep -E "^$1=" .env 2>/dev/null || true; } | tail -1 | cut -d= -f2- | tr -d '\r'; }

# The tag we are about to run, resolved the same way compose resolves it
# (shell env > .env > the `:-latest` default) — for the messages below only.
env_tag="$(envval SEMANTIUS_DB_VERSION)"
IMAGE_TAG="${SEMANTIUS_DB_VERSION:-${env_tag:-latest}}"

if [ "$PULL" = 1 ]; then
  # The other services are `pull_policy: always`; `postgres` is not, because a
  # locally built image must survive an `up` under --no-pull. So pull it here.
  # NOTE: pulling `latest` OVERWRITES an image you built and tagged yourself.
  echo "== Pulling the published DB image (:${IMAGE_TAG}) =="
  docker compose pull postgres
else
  echo "== Skipping the DB pull — running the locally tagged image (:${IMAGE_TAG}) =="
fi

# --force-recreate: always replace existing containers with fresh ones built from
# the current compose config, so this can never resume a stale/half-built container
# (e.g. one left port-unpublished by an earlier failed `up`). --remove-orphans drops
# containers for services no longer in the compose file. Data lives in named
# volumes, so this does NOT lose data — only ./create.sh and ./destroy.sh do.
docker compose up -d --force-recreate --remove-orphans
docker compose ps

web_port="$(envval WEB_PORT)"
postgres_port="$(envval POSTGRES_PORT)"
authenticator_password="$(envval SEMANTIUS_AUTHENTICATOR_PASSWORD)"
echo
echo "Ready (Semantius stack)."
echo "  Image : ghcr.io/semantius/postgres:${IMAGE_TAG}  ($([ "$PULL" = 1 ] && echo pulled || echo 'local tag, not pulled'))"
echo "  Admin : http://localhost:${web_port:-3000}/   (SPA; API at /rest/, docs at /api-docs/)"
echo "  DBA   : postgresql://postgres:<POSTGRES_PASSWORD>@localhost:${postgres_port:-5434}/semantius"

# The idp warns about its own shipped defaults (IDP_SECRET, POSTGRES_PASSWORD)
# on its admin pages, but SEMANTIUS_AUTHENTICATOR_PASSWORD never reaches it —
# this is the only place that can notice it.
if [ "${authenticator_password:-devpassword}" = "devpassword" ]; then
  echo
  echo "  WARNING: SEMANTIUS_AUTHENTICATOR_PASSWORD is still the shipped default"
  echo "  ('devpassword') — the login PostgREST uses against the database. Fine"
  echo "  locally; change it in .env before exposing this deployment, then ./up.sh."
fi

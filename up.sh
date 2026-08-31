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

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example — edit passwords/ports if you want."
fi

# An explicit tag wins over .env: the shell environment takes precedence over the
# .env file in docker compose's variable resolution.
if [ -n "$DB_VERSION" ]; then
  export SEMANTIUS_DB_VERSION="$DB_VERSION"
  echo "Pinning SEMANTIUS_DB_VERSION=${DB_VERSION} for this run."
fi

# The tag we are about to run, resolved the same way compose resolves it
# (shell env > .env > the `:-latest` default) — for the messages below only.
# Captured NOW because the summary at the end re-sources .env.
env_tag="$(grep -E '^SEMANTIUS_DB_VERSION=' .env 2>/dev/null | tail -1 | cut -d '=' -f2- | tr -d '\r' || true)"
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

set -a; . ./.env; set +a
echo
echo "Ready (Semantius stack)."
echo "  Image : ghcr.io/semantius/postgres:${IMAGE_TAG}  ($([ "$PULL" = 1 ] && echo pulled || echo 'local tag, not pulled'))"
echo "  Admin : http://localhost:${WEB_PORT:-3000}/   (SPA; API at /rest/, docs at /api-docs/)"
echo "  DBA   : postgresql://postgres:<POSTGRES_PASSWORD>@localhost:${POSTGRES_PORT:-5434}/semantius"

# The idp warns about its own shipped defaults (IDP_SECRET, POSTGRES_PASSWORD)
# on its admin pages, but SEMANTIUS_AUTHENTICATOR_PASSWORD never reaches it —
# this is the only place that can notice it.
if [ "${SEMANTIUS_AUTHENTICATOR_PASSWORD:-devpassword}" = "devpassword" ]; then
  echo
  echo "  WARNING: SEMANTIUS_AUTHENTICATOR_PASSWORD is still the shipped default"
  echo "  ('devpassword') — the login PostgREST uses against the database. Fine"
  echo "  locally; change it in .env before exposing this deployment, then ./up.sh."
fi

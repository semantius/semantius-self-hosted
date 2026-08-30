#!/usr/bin/env bash
# create.sh  -  create the stack FROM SCRATCH: fresh containers AND a fresh
# database. The exact inverse of destroy.sh.
#
# The stack is PostgreSQL 18 + the pg_semantius extension, fronted by PostgREST
# (HTTP + OpenAPI), a Scalar docs site, a bundled OIDC identity provider and the
# Caddy front door. It runs as its own compose project (semantius, set by `name:`
# in docker-compose.yml).
#
# WHY IT WIPES: the image's first-init scripts (CREATE EXTENSION, the authenticator
# LOGIN, anon, the optional NWIND load) run ONCE per data directory. Recreating
# containers over an existing pgdata volume silently keeps the OLD schema — so
# "create" would hand you a stale database and a test that proves nothing. A fresh
# container is not a fresh database; only dropping the volume makes it one.
#
# EVERY IMAGE COMES FROM A REGISTRY. Nothing here is built from source, so a fresh
# clone can create the stack with no toolchain installed.
#
# DESTRUCTIVE: deletes this stack's volumes. Prompts when a data volume exists;
# bypass with -y/--yes, ASSUME_YES=1 or CI=true. To KEEP your data — after a
# compose/.env/Caddyfile change — use ./up.sh instead.
#
# Usage:
#   ./create.sh                  fresh DB on the published image (what a server runs)
#   ./create.sh 0.4.0-pg18       ... pinned to that tag
#   ./create.sh --no-pull        fresh DB on the locally tagged image (see up.sh)
#   ./create.sh -y               skip the confirmation prompt
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '/^# Usage:/,/skip the confirmation prompt/p' "$0" | sed 's/^# \{0,1\}//'; }

PULL=1; FORCE=0; DB_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-pull) PULL=0 ;;
    --pull)    PULL=1 ;;   # the default; accepted so it can be stated explicitly
    -y|--yes)  FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "Unknown option: $1" >&2; echo >&2; usage >&2; exit 1 ;;
    *)         DB_VERSION="$1" ;;   # a bare argument is the image tag
  esac
  shift
done

if [ "$PULL" = 0 ] && [ -n "$DB_VERSION" ]; then
  echo "A version tag ('$DB_VERSION') applies only when pulling — --no-pull runs whatever is tagged locally." >&2
  exit 1
fi

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example — edit passwords/ports if you want."
fi

# Only prompt when there is actually data to lose. The compose project name is
# parsed from `name:` in docker-compose.yml so it stays a single source of truth,
# and the volumes are found by the label compose stamps on them.
PROJECT="$(sed -nE 's/^name:[[:space:]]*([^[:space:]#]+).*/\1/p' docker-compose.yml | head -1)"
VOLUMES="$(docker volume ls -q --filter "label=com.docker.compose.project=${PROJECT}" 2>/dev/null || true)"

if [ -n "$VOLUMES" ]; then
  if [ "$FORCE" != 1 ] && [ "${ASSUME_YES:-}" != "1" ] && [ "${CI:-}" != "true" ]; then
    echo "An existing database volume was found for '${PROJECT}':"
    echo "$VOLUMES" | sed 's/^/  /'
    read -r -p "create DELETES it (all data) and starts from scratch. Continue? [y/N] " ans
    case "$ans" in y|Y) ;; *) echo "Cancelled. (./up.sh recreates the containers and KEEPS the data.)"; exit 0 ;; esac
  fi
  echo "== Wiping the stack + its volumes (down -v) =="
else
  echo "== No existing volumes — creating the stack from scratch =="
fi
docker compose down -v

# Everything past the wipe is exactly `up`, so it lives in one place.
UP_ARGS=""
if [ "$PULL" = 0 ]; then UP_ARGS="--no-pull"; fi
if [ -n "$DB_VERSION" ]; then UP_ARGS="$UP_ARGS $DB_VERSION"; fi
# shellcheck disable=SC2086
exec ./up.sh $UP_ARGS

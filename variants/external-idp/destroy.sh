#!/usr/bin/env bash
# Destroy the PostgREST stack: its containers, network, and data + jwks volumes.
# Keeps the semantius/postgres image (a reusable, versioned artifact — rebuild/pull as
# needed) and leaves the pgdocker stacks untouched.
set -euo pipefail
cd "$(dirname "$0")"

read -r -p "This DELETES the PostgREST stack's DB volume (all data). Continue? [y/N] " ans
case "$ans" in
  y|Y) ;;
  *) echo "Cancelled."; exit 0 ;;
esac

# --remove-orphans as well: a bare `down` only removes containers for services
# CURRENTLY in the compose file, so one left behind by a RENAMED service (the SPA
# was `web` before it became `nginx`) survives the wipe — and then collides with
# the new service over its `container_name:`, failing the next up with
# "Conflict. The container name /semantius-app is already in use". up.sh passes
# the same flag, but that one is too late: compose drops orphans AFTER creating
# the service containers, i.e. after the conflict has already fired.
docker compose down -v --remove-orphans
echo "Removed the PostgREST stack's containers, network, and data + jwks volumes (image kept)."

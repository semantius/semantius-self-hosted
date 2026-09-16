#!/usr/bin/env bash
# dokploy-build.sh  -  regenerate the Dokploy blueprint in ./dokploy/ from this
# folder's docker-compose.yml + Caddyfile.
#
# ./dokploy/ is GENERATED and COMMITTED — never hand-edit it. Change the two
# sources here, run this, and commit the result.
#
# The transform (and its validations) live in scripts/dokploy-build.mjs; this is
# just the entry point, so the blueprint is regenerated the same way as every other
# stack operation (create/up/start/...) rather than via an npm script.
#
# Needs Node (the script uses the `yaml` package — run `npm install` once if it is
# missing).
set -euo pipefail
cd "$(dirname "$0")"

command -v node >/dev/null 2>&1 || { echo "node not found — install Node.js (>=18) to build the blueprint." >&2; exit 1; }

node scripts/dokploy-build.mjs "$@"

#!/usr/bin/env bash
# build.sh  -  regenerate ./variants/ from ./templates/.
#
# TEMPLATES ARE WHAT YOU EDIT, VARIANTS ARE WHAT YOU RUN. Every folder under
# variants/ is GENERATED and COMMITTED — never hand-edit one. Change a file in
# templates/, run this, commit the result.
#
# A variant subtracts from the one stack in templates/: `x-semantius-feature:`
# keys mark compose nodes and `# >>> feature:<name>` pairs mark regions of the
# text files, and templates/<variant>/variant.json says which features to drop,
# which variables the variant cannot start without, and what its defaults are.
#
# A generated folder keeps its own .env — yours, with your passwords — and a
# rebuild never touches it.
#
# Usage:
#   ./build.sh                 build every variant
#   ./build.sh external-idp    build one
#
# The transform and its validations live in scripts/build.mjs; this is
# just the entry point.
#
# Needs Node (the script uses the `yaml` package — run `npm install` once if it
# is missing).
set -euo pipefail
cd "$(dirname "$0")"

command -v node >/dev/null 2>&1 || { echo "node not found — install Node.js (>=18) to build the variants." >&2; exit 1; }

node scripts/build.mjs "$@"

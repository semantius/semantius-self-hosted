# TODO — self-hosting stack (Caddy front door + Dokploy blueprint)

Open items left over from the front-door / blueprint work. Everything else in
that change is implemented and verified (see [README.md](README.md)).

## Blocking a publish

- [ ] **1. Add `logo.svg` at the repo root.** `dokploy/meta.json` references
      `logo.svg` and `./build.sh` copies it into `dokploy/` when it exists
      — right now it doesn't, so the build prints a MISSING reminder and the
      gallery card would render without a logo. Drop the Semantius SVG in and
      re-run the build.

- [ ] **2. Dokploy round-trip test** (needs a Dokploy instance). Import the blueprint
      — fork [Dokploy/templates](https://github.com/Dokploy/templates) as
      `blueprints/semantius/`, or **Create Service → Advanced → Import → Base64** —
      deploy it, and confirm:
      - the `configs:` block survives Dokploy's compose processing (the one
        residual unknown; needs docker compose ≥ 2.23.1 on the server),
      - Traefik routes `${main_domain}` → `caddy`:80,
      - `/`, `/rest/`, `/gateway/rest/`, `/api-docs/` all work at `https://<domain>`,
      - the identity provider works end to end: `/idp` serves the setup page, its
        two embedded `semantius-idp-config/*.jsonc` configs arrive with their `${env:…}`
        placeholders intact, `/.well-known/openid-configuration` (and the RFC 8414
        suffix form `/.well-known/oauth-authorization-server/idp`) resolve, and a
        login through the SPA completes.

## Follow-ups

- [ ] **3. `read_only: true` is dropped from `idp` in the blueprint.** Not a choice:
      docker compose delivers an inline `configs.content` by writing it into the
      container filesystem and refuses outright on a read-only service
      (*"cannot create config … in read-only service: `file` is the sole supported
      option"*). The generator strips it and says so. To get it back, the
      blueprint would have to ship the config as a `file:` config — which means
      files beside the compose, the thing a one-click blueprint exists to avoid.

- [ ] **4. Clean self-hosted opt-out in the `semantius-app` repo.** The `web` service
      has to pass `VITE_CONTROL_PLANE_URL: " "` — a literal single space — because
      unset *or empty* falls through to the baked cloud default. Make `runtimeEnv`
      honour an explicit empty value (or `none`) in `window.__ENV__`, then replace
      the whitespace hack here and drop the warnings in `docker-compose.yml` and
      `README.md`.

- [ ] **5. Regeneration drift guard.** `dokploy/` is generated and committed, so it can
      silently go stale when `docker-compose.yml` or `Caddyfile` change. Add a CI
      step that runs `./build.sh` and fails if the working tree is dirty.

- [ ] **6.** *(optional)* Have `build` also emit the Dokploy Base64 import blob, so
      importing into an instance is copy-paste with no manual encoding step.

## Entra test tenant (wdbm6) — drift found 2026-09-17

- [ ] **7. "Assignment required" is OFF on the `Semantius API` enterprise app.**
      `setup-entra.ps1` sets it (`appRoleAssignmentRequired = $true`), and the
      script's docstring states it as fact — but Graph reports `false` on
      service principal `4e867e44-402f-4c9d-aff5-3a3c5ffaf05f`. The patch is
      wrapped in a non-fatal `try/catch` that only prints a yellow warning, so
      either it failed on the last run and the warning went unread, or it was
      switched off in the portal afterwards. **Not verified which.**
      Effect: any user in the tenant can obtain a token for the API. They land
      as `anon` in PostgREST (no `roles` claim), so the stack is not open — but
      the documented outer gate is not on. `./setup-entra.ps1 -Verify` now
      reports it as an advisory; flip it back under Enterprise applications >
      Semantius API > Properties, or re-run the script.

- [ ] **8. `Semantius App` carries a second origin, `http://localhost:53999`,**
      alongside `http://localhost:3000`. Not derivable from `.env`
      (`WEB_PORT=3000`), so it came from a `-FrontDoorUrl` run or a hand edit —
      **origin not established.** Consequence: a re-run of `setup-entra.ps1`
      for `localhost:3000` now throws at the `-Shared` guard, *after* step 1
      has already re-applied the API's optional claims. Decide whether the URI
      should stay (then use `-Shared`) or be removed. Worth noting the guard
      reads as "nothing happened" when it is not quite true — the script is
      not atomic across that throw.

## Unrelated observation

- [ ] **9.** After OIDC login the web app shows **"You don't have access to any
      modules"** for `user1`. Not a routing problem — `/api/modules` returns 200
      through the front door, and `/rpc/get_userinfo` reports a role on module 1.
      Looks like RBAC/data state or an app-side query; worth a look separately.

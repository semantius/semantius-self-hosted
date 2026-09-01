# Semantius — self-hosting stack

Everything needed to **self-host Semantius**: a Docker Compose stack that puts an
HTTP API with browsable OpenAPI docs, an admin SPA and an **OIDC identity
provider** in front of a PostgreSQL 18 database carrying the `pg_semantius`
extension — plus a one-click [Dokploy blueprint](#dokploy-one-click-template)
generated from it.

Auth is part of the stack rather than a prerequisite for it: the bundled `idp`
service issues the bearer tokens and publishes the keys PostgREST validates them
against, so a fresh `create` is a complete, self-hosted system with nothing to
register anywhere.

**Every image is pulled from a registry — nothing here is built from source.** A
fresh clone of this repo plus Docker is the whole prerequisite list. Everything
the database needs (extension install, roles, `pg_hba`, the authenticator LOGIN,
optional demo data) is baked into the `ghcr.io/semantius/postgres` image, so the
database side mounts nothing from the host. The only host files the stack reads
are the sibling [`Caddyfile`](Caddyfile) and [`idp-config/`](idp-config/) —
deliberately plain, editable files. The deployment variant in
[`dokploy/`](#dokploy-one-click-template) embeds all of them, so a one-click
deploy really is just one compose file (see below).

> Semantius itself — the extension, the migration framework and the CLI — lives in
> [semantius/semantius](https://github.com/semantius/semantius). This repo is only
> the deployment stack; it consumes the published images.

A single **Caddy front door** on `WEB_PORT` fans out to the four HTTP services —
the **only** published HTTP port; every URL the stack emits carries the front
door's origin, so that is the only address that is ever correct to use. Only the
data tier (Postgres, PgBouncer) publishes ports of its own, for SQL clients
Caddy cannot front.

```mermaid
flowchart LR
    browser(["browser"])
    sql(["direct database access<br/><i>your app, psql, tooling</i>"])
    caddy["Caddy<br/>:3000"]

    subgraph edge["behind the front door"]
        direction TB
        spa["Frontend App<br/>static build on nginx :80"]
        idp["semantius-idp"]
        scalar["Scalar docs"]
        rest["PostgREST<br/>OpenAPI at /"]
    end

    subgraph data["data tier"]
        direction TB
        pgb["PgBouncer<br/>:6432 · transaction pooling"]
        pg[("Postgres 18 + pg_semantius<br/>:5434")]
    end

    browser --> caddy
    caddy -->|"/"| spa
    caddy -->|"/idp/*"| idp
    caddy -->|"/.well-known/*<br/><i>issuer metadata, at the ORIGIN ROOT</i>"| idp
    caddy -->|"/gateway*<br/><i>rewritten onto /idp/gateway/*<br/>/gateway/rest fronts PostgREST</i>"| idp
    caddy -->|"/api-docs/*"| scalar
    caddy -->|"/rest/*"| rest
    spa -.->|"/rest/* with Bearer jwt<br/>back through Caddy"| rest

    idp -->|"runtime pool, as postgres<br/>schema idp: users, OAuth clients, signing keys"| pgb
    sql -->|"pooled :6432 — as semantius_authenticator<br/>needs the SET LOCAL ROLE pattern"| pgb
    sql -->|"unpooled :5434 — when you need session state<br/>LISTEN/NOTIFY, advisory locks, prepared statements"| pg
    pgb --> pg
    rest -->|"SCRAM as semantius_authenticator<br/>SET ROLE authenticated or anon, per request"| pg
```

**What the boxes are.** Eight containers, and only three of them are ours — the
rest are stock upstream images, unmodified:

| In the diagram | Image | Upstream |
|---|---|---|
| Caddy | `caddy:2-alpine` | [caddyserver.com](https://caddyserver.com) · [caddyserver/caddy](https://github.com/caddyserver/caddy) |
| Frontend App | `ghcr.io/semantius/semantius-app` | the Semantius admin SPA, a static build served by [nginx](https://nginx.org) — published by the Semantius project |
| semantius-idp | `ghcr.io/semantius/semantius-idp` | [semantius/semantius-idp](https://github.com/semantius/semantius-idp) |
| Scalar docs | `scalarapi/api-reference` | [scalar.com](https://scalar.com) · [scalar/scalar](https://github.com/scalar/scalar) |
| PostgREST | `postgrest/postgrest` | [postgrest.org](https://postgrest.org) · [PostgREST/postgrest](https://github.com/PostgREST/postgrest) |
| PgBouncer | `edoburu/pgbouncer` | [pgbouncer.org](https://www.pgbouncer.org) · image: [edoburu/docker-pgbouncer](https://github.com/edoburu/docker-pgbouncer) |
| Postgres 18 + pg_semantius | `ghcr.io/semantius/postgres` | [postgresql.org](https://www.postgresql.org) + the extension, built from [`docker-postgres/`](https://github.com/semantius/semantius/tree/main/docker-postgres) |
| *(not drawn — one-shot, exits)* | `curlimages/curl` | [curl.se](https://curl.se) · image: [curl/curl-container](https://github.com/curl/curl-container) |

Service names, container names, host ports and what each one actually does:
[Services & images](#services--images) below.

## Quick start

```bash
git clone https://github.com/semantius/semantius-self-hosted
cd semantius-self-hosted
./setup-env.sh         # .env from .env.example, with generated secrets (Windows: setup-env.cmd)
./create.sh            # pull the images + a FRESH database, stack up (Windows: create.cmd)
```

`create` runs `setup-env` for you when `.env` is missing, so the explicit call
above is only worth making when you want to look the file over before booting.
Either way the three secrets in the new `.env` are freshly generated, never the
values `.env.example` carries — see [the three per-installation secrets](#the-three-per-installation-secrets).

Then open **http://localhost:3000/** — the admin SPA. It sends you to sign in,
and while the idp's user table is empty the sign-in page *is* the first-run setup
page: whoever completes it becomes the first administrator and lands back in the
SPA. There is no bootstrap account and no password in the environment.

- **Front door:** http://localhost:3000 — admin SPA at `/`, API at `/rest/`
  (or `/gateway/rest/` for the same API through the idp's authenticating proxy,
  which accepts an API key), docs at `/api-docs/`, identity provider at `/idp/`.
  It is the only published HTTP port — every URL the stack emits carries its
  origin, so PostgREST, Scalar and the idp are deliberately not reachable any
  other way.

Then, day to day — every command is a script in **this folder**, `.sh` for bash and
`.cmd` for Windows ([full table below](#management-scripts)):

```bash
./up.sh                  # re-apply compose/.env/Caddyfile/idp-config changes  (KEEPS the data)
./status.sh              # what's running
./stop.sh  /  ./start.sh # stop / restart the containers (data kept)
./jwks-refresh.sh        # re-fetch the issuer keys after a rotation
./dokploy-build.sh       # regenerate the dokploy/ blueprint from this stack
./destroy.sh             # remove containers + volumes              (all data gone)
```

### `create` vs `up` — a fresh *container* is not a fresh *database*

The image's first-init scripts (`CREATE EXTENSION`, the authenticator LOGIN,
`anon`, the optional `NWIND` load) run **once per data directory**. Recreating
containers over an existing `pgdata` volume therefore keeps the **old** schema, no
matter how clean the containers are — which is why these are two commands rather
than one command with a flag:

| | wipes the DB? | use it when |
|---|---|---|
| **`create`** | **yes** — `down -v` first, so the image installs itself from scratch | you want a clean database: first run, after changing migrations or init scripts, or to test an image honestly. Prompts when a volume exists (`-y` skips) |
| **`up`** | no — containers only | you changed `docker-compose.yml`, `.env`, the `Caddyfile` or `idp-config/*.jsonc` and want it applied to the **running data** |

`create` is the exact inverse of `destroy`; `up` is `docker compose up
--force-recreate` with the image pull in front of it. Reach for `up` when you
meant `create` and the symptom is a database that stubbornly reflects the previous
version — that is the init-once rule, not a broken image.

### Pinning a version

`create` and `up` **pull the DB image from GHCR**, like every other service in this
stack. A bare argument pins the tag:

```bash
./create.sh                  # fresh DB on the published image (tag from .env, default latest)
./create.sh 0.4.0-pg18       # ... pinned to a released tag
./up.sh     0.4.0-pg18       # swap the running stack onto that tag, keep the data
```

Set `SEMANTIUS_DB_VERSION` in `.env` to make a pin permanent (there are matching
`SEMANTIUS_APP_VERSION` and `SEMANTIUS_IDP_VERSION` vars for the SPA and the idp).

> **Developing the extension itself?** The image is built from `docker-postgres/`
> in [semantius/semantius](https://github.com/semantius/semantius) — that repo's
> `docker-postgres/build.sh` packages your working tree and tags it `:latest`, and
> its `docker-compose/test.sh` drives this stack against it. Both `create` and `up`
> take **`--no-pull`** so they use that local tag instead of overwriting it with a
> fresh pull; a version tag names a *published* image, so it cannot be combined
> with `--no-pull`.

## Services & images

Eight services (compose project `semantius`), seven long-running + one one-shot.
The **container** names say what each one is rather than repeating the service
name — `postgrest` runs as `semantius-api`, `scalar` as `semantius-docs`, `nginx`
as `semantius-app`, `jwks-fetch` as `semantius-jwks`; the rest match
(`semantius-postgres`, `-pgbouncer`, `-idp`, `-caddy`). Use the **service** name
with `docker compose`, the **container** name with plain `docker`:

| Service | Image | Host port | Purpose |
|---|---|---|---|
| `postgres` | `ghcr.io/semantius/postgres:${SEMANTIUS_DB_VERSION}` (built from [`docker-postgres/`](https://github.com/semantius/semantius/tree/main/docker-postgres)) | **5434** | PG18 with the extension installed + roles/pg_hba/authenticator/nwind baked in |
| `pgbouncer` | `edoburu/pgbouncer:latest` | **6432** | transaction-pooled `semantius_authenticator` endpoint for apps that talk SQL directly ([see below](#the-pgbouncer-service--a-pooled-endpoint-for-external-apps)) |
| `idp` | `ghcr.io/semantius/semantius-idp:${SEMANTIUS_IDP_VERSION}` | — | **the bundled OIDC/OAuth issuer**, served at `/idp` — signs the bearer tokens and publishes the JWKS ([see below](#the-idp-service--the-bundled-identity-provider)). Shares `postgres` in its own `idp` schema; configured by [`idp-config/*.jsonc`](idp-config/) |
| `jwks-fetch` | `curlimages/curl:latest` | — | **one-shot**: downloads the issuer JWKS to a file PostgREST can read (see below) |
| `postgrest` | `postgrest/postgrest:latest` | — | HTTP API; verifies the JWT vs the JWKS; serves OpenAPI at `/`. Reach it through `semantius` (`/rest/`, `/gateway/rest/`) |
| `scalar` | `scalarapi/api-reference:latest` | — | renders PostgREST's Swagger 2.0 spec as browsable docs. Reach it through `semantius` (`/api-docs/`) |
| `nginx` | `ghcr.io/semantius/semantius-app:${SEMANTIUS_APP_VERSION}` | — | static admin SPA (nginx). **SPA only** — it proxies nothing; reach it through `semantius`. Runtime config is written to `config.js` (`window.__ENV__`) at container start from its `VITE_*` env by the image's `gen-config.sh`, so one image serves every environment — but only the names on that script's canonical list are emitted, so a **new** `VITE_*` setting needs an app image that knows it |
| `semantius` | `caddy:2-alpine` | **3000** | **front door**: `/` → the SPA, `/rest/*` → PostgREST, `/api-docs/*` → Scalar (both prefixes stripped), `/idp/*` and `/.well-known/*` → the idp (prefix **kept**), `/gateway*` → the idp, **rewritten** onto `/idp/gateway` so the caller's URL stays short (safe only because the idp's session cookie is host-wide — see `cookiePath` in [`idp-config/config.jsonc`](idp-config/config.jsonc)). `/gateway/rest/*` therefore reaches **the same PostgREST** as `/rest/*`, with the idp's API-key→JWT exchange in front of it — and, because the idp session cookie is host-wide, a signed-in browser authenticates there automatically, which is what makes the Scalar docs' "Test Request" work with no credential to paste. One rule supports that: `@pgrstDocsAccept` collapses the four-content-type `Accept` header Scalar generates down to `application/json`, without which PostgREST answers `406 PGRST116` on every multi-row endpoint. Routes live in the sibling [`Caddyfile`](Caddyfile) — edit it and `docker compose restart semantius` |

The registry images use `:latest` and `pull_policy: always` (re-pulled on every
`create`); `postgres` is the locally-built image, used as-is. Pin
`postgrest`/`scalar` to fixed tags once you're happy.

> **The SPA's control plane is opt-OUT.** The `nginx` service sets
> `VITE_CONTROL_PLANE_URL: " "` — a **single space**, and it is load-bearing.
> Unset *or empty* leaves the image's cloud default in place, which sends the app
> to `api.semantius.cloud` for a tenant lookup and fails to boot when self-hosted;
> a whitespace value survives the runtime-env filter and trims to `""` in the app,
> selecting self-hosted mode. Don't "tidy" it away — the comment in
> `docker-compose.yml` says the same thing next to the line.
>
> **Same shape, second setting.** `VITE_BACKEND_TYPE: self_hosted` picks the
> user menu, and unset *or empty* means `cloud` — the hosted account/billing
> entries, which do not exist here. `self_hosted` renders `/idp/account` and
> `/idp/admin`, the pages this stack really serves. Like the control-plane URL
> it is pinned in the compose rather than exposed in `.env`: this deployment
> *is* the self-hosted backend. (`custom` is the third value, and needs
> `VITE_UI_CUSTOMIZER` to carry a JSON user menu; anything else is a blocking
> config error at boot.)

## Environment variables (`.env`)

Every variable the **compose file** consumes. Run `./setup-env.sh` to write
`.env` from `.env.example` with generated secrets (or copy it by hand and set
those three yourself), then edit. `.env` is gitignored; `.env.example` is the
committed template.

The `.env` groups these into a **change-first** block (your OIDC issuer) and a
**defaults** block; the table below follows that order.

| Var | Default | Used by | Purpose |
|---|---|---|---|
| `IDP_SECRET` | **(required)** — generated by `setup-env` | `idp` | Signs the idp's sessions **and encrypts its JWT signing keys at rest**. ≥ 32 random bytes (`openssl rand -base64 48`). Change it for anything shared or exposed — and treat rotating it as a key rotation: it logs everyone out and makes the stored signing keys undecryptable. |
| `SEMANTIUS_IDP_VERSION` | `latest` | `idp` | Tag of the `semantius-idp` image. Re-pulled on every `create`; pin for reproducible/server deploys. |
| `IDP_BASE_URL` | `http://localhost:${WEB_PORT}/idp` | `idp` | The **canonical issuer**: scheme + host + the `/idp` mount path, no trailing slash. Every absolute URL the idp emits derives from it — **e-mail links always do**, even with `IDP_DYNAMIC_ISSUER` on. ⚠️ **Set going live** (`https://yourdomain.com/idp`), and update it once after attaching a different domain (for the e-mail links). |
| `IDP_DYNAMIC_ISSUER` | `false` | `idp` | Derive the issuer (and every browser-facing URL **except e-mail links**) per request from the arriving host. Setting it `true` is *your* assertion about the ingress — see [Serving more than one domain](#serving-more-than-one-domain-idp_dynamic_issuer) below. The Dokploy blueprint sets it. |
| `PUBLIC_WEB_ORIGIN` | `http://localhost:${WEB_PORT}` | `idp` | Origin of the admin SPA, no path. [`idp-config/oauth_clients.jsonc`](idp-config/oauth_clients.jsonc) builds the SPA's redirect URIs from it, **matched exactly**. With `IDP_DYNAMIC_ISSUER=true` it may be the template `https://{host}` — the idp substitutes the request's whole host (not a wildcard; `*` stays refused). ⚠️ **Set going live.** |
| `RESEND_API_KEY` | *(unset)* | `idp` | Optional. Without it the idp runs **degraded**: password reset, e-mail verification and all notifications are disabled and hidden. Fine locally (admins create users); set it for anything real. |
| `VITE_OAUTH_CONFIG` | `/.well-known/openid-configuration` (relative) | `nginx`, `jwks-fetch` | OIDC discovery URL. The admin SPA resolves its OAuth endpoints from it — the relative default is resolved **by the browser**, so discovery follows whatever host the app is open on. `jwks-fetch` derives the JWKS from its `jwks_uri` when `JWKS_URL` is empty; set it (**absolute** — that container curls it directly) only to **replace** the bundled issuer. |
| `VITE_OAUTH_CLIENT_ID` | `public-client` | `nginx` | Public OAuth client id. Matches the SPA registered in [`idp-config/oauth_clients.jsonc`](idp-config/oauth_clients.jsonc). |
| `VITE_OAUTH_AUDIENCE` | `${IDP_JWT_AUDIENCE}` (`semantius://api`) | `nginx` | The RFC 8707 `resource` the SPA asks its access tokens to be issued for — it becomes their `aud`. **Load-bearing:** the SPA always sends one (falling back to a built-in placeholder when empty) and an issuer that validates resources rejects an unknown one, showing a bare *Login Error* on `/oauth2_callback`. Change it only with an external issuer. |
| `IDP_JWT_AUDIENCE` | `semantius://api` | `idp`, `nginx` | The audience the bundled idp registers and mints as `aud`, and the default of `VITE_OAUTH_AUDIENCE` — one var moves both sides. A **fixed URI** on purpose: an audience derived from the issuer URL goes stale the moment a domain is attached after deploy. Seeding `_settings.jwt_aud`? Seed exactly this value. |
| `JWKS_URL` | `http://idp:3000/idp/.well-known/jwks.json` | `jwks-fetch` | Keys PostgREST validates bearer tokens against. Defaults to the bundled idp **in-network** — explicit rather than derived, because the `jwks_uri` the idp advertises carries its *public* URL, which that container can't resolve. Set it **empty** (present in `.env`, no value) to derive from `VITE_OAUTH_CONFIG`'s discovery document instead — what an external issuer wants. The compose uses `${JWKS_URL-…}`, not `${JWKS_URL:-…}`, so an empty value stays empty. |
| `POSTGRES_PASSWORD` | **(required)** | `postgres` | `postgres` DBA login password. The stack refuses to start if unset. |
| `POSTGRES_DB` | `semantius` | `postgres`, `postgrest` | Database created on first init and served by the API. |
| `SEMANTIUS_AUTHENTICATOR_PASSWORD` | **(required)** — generated by `setup-env` | `postgres`, `postgrest` | Password for `semantius_authenticator`, the role PostgREST logs in as. Consumed by the image's baked `20-authenticator-login.sh` **and** by `PGRST_DB_URI` — kept in sync automatically. Per-environment secret; the stack refuses to start if unset. |
| `SEMANTIUS_DB_VERSION` | `latest` | `postgres` | Tag of the `semantius/postgres` image to run. Pin (e.g. `0.3.0-pg18`) for reproducible/server deploys; `latest` tracks your local `docker-postgres/build.sh`. |
| `SEMANTIUS_APP_VERSION` | `latest` | `nginx` | Tag of the `semantius/semantius-app` admin SPA image. Re-pulled on every `create`; pin for reproducible/server deploys. |
| `NWIND` | *(unset)* | `postgres` | Set to **any** non-empty value (e.g. `TRUE`) to load the optional Northwind demo module on first init. Takes effect only on a **fresh** data volume (init runs once). |
| `POSTGRES_PORT` | `5434` | `postgres` | Host port for Postgres (5432/5433 belong to pgdocker's cli/ext stacks). |
| `PGBOUNCER_PORT` | `6432` | `pgbouncer` | Host port for the transaction-pooled PgBouncer endpoint. |
| `WEB_PORT` | `3000` | `semantius` | Host port of the **front door** — the only published HTTP port: `/` the SPA, `/rest/*` the API, `/api-docs/*` the docs, `/idp/*` the identity provider. PostgREST, Scalar, the idp and the SPA have no host ports of their own. |
| `SITE_ADDRESS` | `:80` | `semantius` | The address Caddy serves inside the container. `:80` is plain HTTP — right for local dev and behind anything that terminates TLS (Dokploy/Traefik). On a **bare VPS** set your bare domain for automatic HTTPS, then publish `80:80` + `443:443` on `semantius` instead of `WEB_PORT`. That topology answers **every** Host pointed at the server, so it is **not** eligible for `IDP_DYNAMIC_ISSUER`. |
| `PUBLIC_API_URL` | `http://localhost:${WEB_PORT}/gateway/rest` | `postgrest` | The base URL the OpenAPI spec **advertises** (`PGRST_OPENAPI_SERVER_PROXY_URI`). Cannot be relative — PostgREST parses it into the spec's host/basePath — and never the in-network `postgrest` hostname, because the browser resolves it for "Test Request". It names the **gateway** route rather than the direct `/rest`, which is what lets "Test Request" work with an API key from `/idp/account/api-keys`. Going live, set the public front-door URL **including** `/gateway/rest`. |
| `DOCS_SPEC_URL` | `/gateway/rest` (relative) | `scalar` | Where the docs page fetches the spec itself. Relative on purpose: the browser resolves it against whatever host the docs are open on, so the docs keep loading on a domain attached after deploy — while "Test Request" calls the host advertised by `PUBLIC_API_URL` until that is updated. Rarely needs setting. |

> **Going live?** With the bundled issuer, what a real deployment must set is
> **`IDP_BASE_URL`** and **`PUBLIC_WEB_ORIGIN`** (your public front door, with and
> without the `/idp` path), a real **`IDP_SECRET`**, and the passwords. The
> `VITE_OAUTH_*` trio, `IDP_JWT_AUDIENCE` and `JWKS_URL` are host-independent and
> can be left alone.
> To use **your own issuer** instead, set `VITE_OAUTH_CONFIG`,
> `VITE_OAUTH_CLIENT_ID` and `VITE_OAUTH_AUDIENCE` to its values and `JWKS_URL` to
> empty (so the keys are derived from its discovery document) — the `idp` service
> keeps running but nothing points at it.

### The three per-installation secrets

Three secrets are per-installation. **You do not normally set them yourself:**
`./setup-env.sh` (`setup-env.cmd` on Windows) generates all three when it creates
`.env`, and `up`/`create` call it whenever `.env` is missing — so a stack that was
started the documented way already has unique values. The
[Dokploy blueprint](#dokploy-one-click-template) generates the same three per
deployment. What follows is what they protect, and what a **hand-copied**
`.env.example` leaves you holding.

| Secret | Value in `.env.example` | Generate one by hand | If you leave the example's |
|---|---|---|---|
| `IDP_SECRET` | `dev-only-idp-secret-change-me-…` | `openssl rand -base64 48` | Anyone with the default can forge idp **sessions** and decrypt the stored **JWT signing keys** — i.e. mint tokens PostgREST accepts. ⚠️ **Ordering trap:** it must be right **before first run.** Rotating it later logs everyone out and makes the stored signing keys undecryptable (treat that as a key rotation, not a config tweak) — which is exactly why `setup-env` generates it at `.env` creation rather than warning you afterwards. |
| `POSTGRES_PASSWORD` | `postgres` | `openssl rand -hex 24` | Full-DBA access to the database for anyone who can reach `POSTGRES_PORT`. |
| `SEMANTIUS_AUTHENTICATOR_PASSWORD` | `devpassword` | `openssl rand -hex 24` | The login PostgREST uses; with `PGBOUNCER_PORT` published, anyone who can reach it gets the same database access as the API's `authenticated` role. |

**Hex, not base64, for the two passwords.** Both are spliced into connection URLs
(the idp's `DATABASE_URL`, PostgREST's `PGRST_DB_URI`) which pgbouncer's
entrypoint re-parses with a naive `grep`/`cut` parser, so they must avoid
`@ : / ? #` and spaces — and `openssl rand -base64` emits `/` and `+`.
`IDP_SECRET` is read straight from the environment and never parsed as a URL, so
base64 is fine there.

`setup-env` never touches an **existing** `.env`. To rotate by hand, change the
value and run `./up.sh`; note that the two passwords are baked into the database
by init scripts that run once per data directory, so on a live stack you must
change them in the database too, or recreate with `./create.sh`.

**Not `.env`-driven — hardcoded in the compose:**

- `POSTGRES_USER` — always `postgres`.
- `IDP_CONFIG_DIR` (`/config`) and `IDP_SCHEMA_NAME` (`idp`) — pinned in the
  compose so a stray host value cannot redirect the container to another
  configuration or another schema.
- `VITE_CONTROL_PLANE_URL` (a single space) and `VITE_BACKEND_TYPE`
  (`self_hosted`) — the pair that puts the admin SPA in self-hosted mode, per
  the note above. Pinned, not `.env`-driven.
The `postgrest`, `nginx` and `semantius` services also set fixed operational env
(`PGRST_*`, `VITE_API_BASE_URL`, `VITE_CONTROL_PLANE_URL`, …) inline; those are
documented by comments in `docker-compose.yml` and rarely need changing.

## The `jwks-fetch` service — why it exists

PostgREST validates each request's OIDC bearer token by checking its RS256
signature against the issuer's **JWKS** (public signing keys). But PostgREST
**cannot fetch a JWKS from a URL** — its `jwt-secret` only accepts *inline JSON*
or a *file path* (`@/path`).

`jwks-fetch` bridges that gap: a tiny one-shot `curl` container that, at stack
startup, downloads the JWKS **once** into a shared volume file (`/jwks/jwks.json`)
which PostgREST then reads via `PGRST_JWT_SECRET=@/jwks/jwks.json`. It runs as root
so it can write the fresh named volume, writes the file world-readable (PostgREST
runs as a different user), and PostgREST `depends_on` it with
`service_completed_successfully`.

**Which URL it fetches:**
- If **`JWKS_URL` is set** → it fetches that directly. It **defaults** to the
  bundled idp reached in-network, `http://idp:3000/idp/.well-known/jwks.json`.
  That is explicit rather than derived on purpose: the `jwks_uri` the idp
  advertises in its discovery document is built from its *public* base URL
  (`localhost:3000`), an address this container cannot resolve.
- If **`JWKS_URL` is empty** → it fetches **`VITE_OAUTH_CONFIG`** (the OIDC discovery
  document) and extracts its `jwks_uri`. That is the **external-issuer** path:
  point `VITE_OAUTH_CONFIG` at your issuer and blank `JWKS_URL`, and the SPA and
  the server both flow from the one setting. "Blank" means *present and empty* in
  `.env` — the compose defaults it with `${JWKS_URL-…}` rather than
  `${JWKS_URL:-…}`, so an empty value is honoured instead of quietly taking the
  bundled default back.

It `depends_on` the `idp` being **healthy**, so the default fetch cannot race the
issuer's startup.

- **Fail-closed:** if the issuer or discovery document is unreachable at boot (or the
  discovery document has no `jwks_uri`), `jwks-fetch` exits non-zero and PostgREST
  won't start.
- **Key rotation:** the JWKS is fetched **once per start**. When the issuer
  rotates signing keys, refresh them on demand with **`./jwks-refresh.sh`**
  (Windows: `jwks-refresh.cmd`) — it re-fetches `JWKS_URL` and restarts
  PostgREST so it re-reads the file (a ~1s API blip; the DB stays up). A restart is
  required rather than a reload signal because the key comes from the
  `PGRST_JWT_SECRET` env var, and PostgREST does **not** re-read env-var config on a
  config reload (`SIGUSR2` / `NOTIFY pgrst 'reload config'`).

  Most IdPs rotate slowly and publish new keys ahead of use, so running this on
  demand is usually enough. **Depending on how often your IdP rotates keys, you may
  want to run it on a schedule** — e.g. a daily cron:
  ```cron
  0 3 * * *  cd /path/to/docker-compose && ./jwks-refresh.sh >> /var/log/jwks-refresh.log 2>&1
  ```

## Volumes

| Volume | Mounted by | Holds |
|---|---|---|
| `pgdata` | `postgres` | the database cluster (survives stop/start; removed by `destroy`) |
| `jwks` | `jwks-fetch` (rw), `postgrest` (ro) | the fetched `jwks.json` |
| `caddy_data` | `semantius` | ACME account + issued certificates (only used when `SITE_ADDRESS` is a real domain) |
| `caddy_config` | `semantius` | Caddy's autosaved config |

## Auth model (how a request flows)

End to end, with the bundled issuer:

```mermaid
sequenceDiagram
    participant SPA as Admin SPA (/)
    participant IDP as idp (/idp)
    participant Caddy
    participant PGRST as PostgREST

    SPA->>IDP: authorization_code + PKCE S256
    Note over IDP: signs an ES256 access token carrying<br/>"role": "authenticated" — a static claim,<br/>jwt.claims in idp-config/config.jsonc
    IDP-->>SPA: access token
    SPA->>Caddy: GET /rest/* with Authorization Bearer jwt
    Caddy->>PGRST: proxied
    Note over PGRST: verifies ES256 vs /jwks/jwks.json<br/>reads the .role claim<br/>SET ROLE authenticated
```

That static `role` claim is the whole integration: without it PostgREST falls back
to `anon` and every data request is *permission denied*. An **external** issuer has
to be configured to emit the same claim.

The token's `aud` is the **fixed URI** `semantius://api` (`jwt.audience`,
defaulted from `IDP_JWT_AUDIENCE`) — deliberately independent of the issuer
host, so tokens verify the same on every domain the stack is reached on.
`PGRST_JWT_AUD` is deliberately left unset — `rbac.uid()` enforces the audience
**in the database**, and only when `_settings.jwt_aud` is seeded (off by
default). If you seed it, seed it with exactly the `IDP_JWT_AUDIENCE` value.

PostgREST logs in as **`semantius_authenticator`** (SCRAM, `NOSUPERUSER
NOINHERIT`) and `SET ROLE`s per request:

- **Valid bearer token** → PostgREST validates the signature against `jwks.json`,
  reads the `role` claim (key `.role`) and does `SET ROLE authenticated`,
  publishing the payload to `request.jwt.claims`. `rbac.uid()` reads that, requires
  `role='authenticated'` + a non-empty `sub`, and RLS takes over.
- **No / invalid token** → `SET ROLE anon`. `anon` has schema `USAGE` only (no
  table grants), so any data request fails with *permission denied* before RLS is
  even consulted.

The roles (`authenticated`, `semantius_user`, `semantius_authenticator`) are
created by the extension itself; the `semantius/postgres` image's baked init scripts only
flip `semantius_authenticator` to LOGIN+password and add the `anon` role — this
stack mounts nothing.

### The OpenAPI docs are public, the data is not

`PGRST_OPENAPI_MODE=ignore-privileges` makes PostgREST emit the **full** spec for
the token-less docs request (so Scalar renders every endpoint) while `anon` still
can't read a single row. `PGRST_OPENAPI_SECURITY_ACTIVE=true` adds a JWT bearer
scheme so the docs show an **Authentication** panel — paste `Bearer <token>` from a
signed-in session, or call `/gateway/rest` with an API key
([see below](#minting-a-token-without-a-browser)).

## The `pgbouncer` service — a pooled endpoint for external apps (and the idp)

PgBouncer pools **two logins**, both configured through the single
`DATABASE_URLS` variable (edoburu/pgbouncer's comma-separated multi-user form —
its entrypoint writes one `userlist.txt` entry per distinct user, so nothing has
to be mounted):

- **`semantius_authenticator`**, published on **`localhost:6432`** for apps that
  speak SQL to the database directly instead of going through PostgREST — the
  same role PostgREST uses, so the identical RBAC/RLS rules apply;
- **`postgres`**, the **idp's runtime pool** (its `DATABASE_URL`). Not published
  — it is reached in-network as `pgbouncer:5432`.

Two things that parser earns: every password spliced into `DATABASE_URLS` must be
**URL-safe** (no `@ : / ? #` or spaces), and `IGNORE_STARTUP_PARAMETERS` has to
list **`search_path`** alongside the image's default `extra_float_digits` —
PgBouncer *rejects* an unknown startup parameter with a fatal
`unsupported startup parameter`, and the idp's driver sends a `search_path` as a
best-effort convenience (every query it emits is schema-qualified, so ignoring it
changes nothing). Without that line every idp query through the pooler dies at
connect.

The published endpoint:

```
postgresql://semantius_authenticator:${SEMANTIUS_AUTHENTICATOR_PASSWORD}@localhost:${PGBOUNCER_PORT}/${POSTGRES_DB}
```

Transaction pooling returns the server connection to the pool at every `COMMIT`, so
the client **must** scope its identity to the transaction — the `SET LOCAL ROLE`
pattern documented in [`pgdocker/README.md`](https://github.com/semantius/semantius/blob/main/pgdocker/README.md):

```sql
BEGIN;
SET LOCAL ROLE authenticated;                             -- transaction-scoped
SELECT set_config('request.jwt.claims', $1::text, true);  -- LOCAL; inject BEFORE any rbac call
-- … queries …
COMMIT;
```

Session-level `SET ROLE` / `set_config(…, false)`, `LISTEN`/`NOTIFY`, session
prepared statements and advisory locks do **not** survive transaction pooling —
never use them on this endpoint.

**What deliberately does *not* go through it:**

- **PostgREST** keeps its direct `postgres:5432` connection: it depends on
  `LISTEN`/`NOTIFY` (`PGRST_DB_CHANNEL_ENABLED=true`) to pick up the CLI's schema
  reloads, which transaction pooling breaks.
- **The CLI / `deno task migrate`** connects directly on **5434** — migrations run
  DDL and session-level state.
- **The idp's own migrations, CLI and cleanup job** use a second, direct URL
  (`DATABASE_URL_ADMIN` → `postgres:5432`): they hold *session* advisory locks,
  which a transaction pooler does not preserve. Only its ordinary runtime traffic
  goes through the pool.

## The `idp` service — the bundled identity provider

[semantius-idp](https://github.com/semantius/semantius-idp) is a full OIDC/OAuth
authorization server, and in this stack it is the **default issuer**. It shares
`postgres` (its own `idp` schema, migrated on boot), holds the users, the OAuth
clients and the signing keys, and needs no volume of its own.

### Mounted at `/idp`, discoverable at the origin root

Caddy proxies `/idp/*` **without stripping the prefix** (`handle`, not
`handle_path`). The prefix is part of the issuer: `server.baseUrl` carries it and
the idp renders every link, cookie `Path`, e-mail URL and redirect from that one
value. Strip it and sign-in *appears* to work while the session cookie is set on a
path the browser never sends back.

The metadata is the mirror-image problem. A client handed the issuer
`<origin>/idp` does **not** fetch `{issuer}/.well-known/...` — RFC 8414 §3.1 puts
the well-known segment *between* the host and the path. So the Caddyfile routes
all of these to the idp:

| Path | Why |
|---|---|
| `/.well-known/openid-configuration` | the root form, used by this stack's own SPA |
| `/.well-known/oauth-authorization-server` | ditto, RFC 8414 spelling |
| `/.well-known/jwks.json` | the signing keys |
| `/.well-known/oauth-authorization-server/idp` | the **RFC 8414 suffix form** a strict client asks for |
| `/.well-known/openid-configuration/idp` | the OIDC-discovery spelling of the same |

Those paths live at the origin root, which otherwise belongs to the SPA, so they
have to be routed explicitly. Nothing does it for you, and the symptom is a client
that cannot discover an idp which is working perfectly.

### Start ordering (why the healthchecks look paranoid)

The idp is the first service in this stack that connects to Postgres over TCP
**without a retry loop of its own**, and it exposed a race the others had been
papering over:

- `postgres`'s healthcheck is `pg_isready -h 127.0.0.1`. The `-h` is
  load-bearing — a bare `pg_isready` uses the unix socket, which starts answering
  during the image's **first-init** phase while the server still runs with
  `listen_addresses=''` and refuses every TCP client. On a fresh volume that gap
  is over a minute. `start_period` covers the init without counting failures.
- the idp's own healthcheck probes **`/idp/readyz`**, not `/idp/healthz`.
  `healthz` is liveness ("the process is up") and answers 200 while the database
  is still unreachable; `readyz` checks config, database, migrations *and* the
  signing key. `jwks-fetch` waits on the idp being healthy before downloading the
  keys, and it is a one-shot — if it fires too early it fails, and `create` fails
  with it.
- `jwks-fetch`'s curl adds `--retry-all-errors` so a 5xx from an
  almost-ready issuer is retried, not just a refused connection.

Both probe URLs carry the `/idp` prefix, because under a sub-path that is where
those endpoints live — a probe of the origin root would report a healthy container
as failing.

### Configuration

Two commented JSONC files in [`idp-config/`](idp-config/), bind-mounted
**read-only** — the container never writes its own configuration:

| File | Holds |
|---|---|
| [`config.jsonc`](idp-config/config.jsonc) | the issuer, the database (pooled + direct), the token shaping, sign-up policy, branding |
| [`oauth_clients.jsonc`](idp-config/oauth_clients.jsonc) | the OAuth clients — the source of truth, reconciled into the database at every start |

They accept `${env:NAME}` / `${env:NAME:-default}` placeholders, resolved from the
`idp` service's environment. Configuration is read **once, at start-up**: edit,
then `docker compose restart idp`. There is no hot reload and `SIGHUP` is ignored.

Four settings there are load-bearing and worth knowing:

- **`database.ssl: "disable"`** — the idp defaults `ssl` to `require` for any
  non-localhost host, and the bundled Postgres speaks plain TCP inside the compose
  network. Without this it cannot connect at all.
- **`jwt.claims: { "role": "authenticated" }`** — the static claim PostgREST maps to
  a database role. A *static* claim, so it belongs here and not in a `roles.jsonc`
  (that file is the per-user catalog, emitted as the `roles` array).
- **`server.trustProxy: true`** — the idp always sits behind this stack's Caddy,
  which sets `X-Forwarded-*` by default.
- **`admin.database: "read-only"`** — turns on `/idp/admin/database`, a schema
  explorer and SQL console over this stack's Postgres (the whole cluster, not just
  the `idp` schema — this stack exposes no `psql`). Every statement runs in a
  READ ONLY transaction, one per run, 10 s timeout, 500 rows, each execution
  audited as `database.queried`. The idp's own default is `disabled`, so this is a
  deliberate departure: an administrator who can run SQL reads every row at rest,
  password hashes and session tokens included. Set it back to `"disabled"` if your
  administrators are not trusted with that; `"read-write"` adds a mode toggle that
  commits.

`server.allowInsecureHttp` is *not* needed for `http://localhost:3000/idp` —
localhost is exempt from the https requirement. Turn it on only to reach a dev
stack over a LAN IP (`http://192.168.x.x:3000/idp`), never on a real deployment.

### Serving more than one domain (`IDP_DYNAMIC_ISSUER`)

By default the issuer is **one URL**: `IDP_BASE_URL`, fixed at boot, whatever
host a request arrives on. `IDP_DYNAMIC_ISSUER=true` makes the idp derive the
issuer **per request** from the host the request arrived on — discovery,
sign-in, authorize, token, the SPA's redirect URIs (via the
`PUBLIC_WEB_ORIGIN=https://{host}` template) and the API all follow every domain
your edge routes, with no restart and no config edit. This is what lets a
Dokploy deployment take a domain attached *after* deploy and just work.

**What deliberately does not follow the request host: e-mail links.** Password
reset and verification links are built from `IDP_BASE_URL` at boot — that is the
property that keeps a forged `Host` header out of a password-reset link. After
attaching a domain, update `IDP_BASE_URL` once for the e-mails.

Turning it on is **your assertion** that all four of these hold for every path
a request can take to the idp:

1. every hop in front of the idp **overwrites** `X-Forwarded-Host` with the
   host it matched;
2. the edge forwards only Hosts matching a configured router;
3. the edge serves a **closed set** of Host values;
4. nothing reaches the container bypassing that edge.

Condition (1) is the one that gets stated wrongly, and it is *not* "a proxy
validates `Host`": the idp reads `X-Forwarded-Host` first, and nginx, an AWS ALB
and a GCP load balancer all **pass an inbound `X-Forwarded-Host` through
untouched** unless configured. For nginx the required line is literally:

```nginx
proxy_set_header X-Forwarded-Host $host;
```

Dokploy's Traefik satisfies all four conditions, and the generated blueprint
sets `IDP_DYNAMIC_ISSUER=true`. A **bare-`SITE_ADDRESS` Caddy deployment does
not** — Caddy configured with one `SITE_ADDRESS=<domain>` still answers *every*
Host pointed at the server, failing condition (3) — so leave the flag off there.

Two more consequences worth knowing, both by design:

- **Sessions and tokens are host-scoped.** The session cookie is host-only, so
  each domain signs in separately; access tokens carry the issuing host as
  `iss` and outstanding ones stop verifying on other hosts for up to their
  15-minute TTL after you switch domains.
- **Social login callbacks stay canonical.** Providers register one callback
  URL, built from `IDP_BASE_URL` — social sign-in works on the canonical host
  only, and the idp logs a boot warning about it when both are enabled.

### Adding an OAuth client

Add an entry to [`oauth_clients.jsonc`](idp-config/oauth_clients.jsonc) and
`docker compose restart idp`. At start-up the file is reconciled into the database
under an advisory lock: new clients are inserted, changed ones updated, and a
client **no longer listed is disabled** and its tokens revoked (deleted instead,
if you set `oauth.reconcile.prune`). Dynamic client registration is off and the
client CRUD endpoints are unreachable, so this file is the only way in.

Redirect URIs are **exact matches, no wildcards**. The shipped SPA entry builds
its one URI as `${PUBLIC_WEB_ORIGIN}/oauth2_callback`, which is what the admin app
actually requests (`${window.location.origin}/oauth2_callback`). A mismatch shows
up as an error page on the idp naming the offending URI.

### Minting a token without a browser

For scripted access to the bundled issuer, use a per-user **API key** — the
supported path (there is no `client_credentials` grant):

1. sign in and create a key at `/idp/account/api-keys`;
2. send the key straight at the **gateway**, which performs the exchange itself
   and injects the bearer token:

```bash
curl -s -H "x-api-key: idp_…" "http://localhost:3000/gateway/rest/_settings?limit=1"
```

   Or do the exchange yourself and call the direct `/rest` route — which is
   exactly what the gateway does on your behalf:

```bash
JWT=$(curl -s -H "x-api-key: idp_…" http://localhost:3000/idp/api/auth/token \
      | sed 's/.*"token":"//; s/".*//')
curl -s -H "Authorization: Bearer $JWT" "http://localhost:3000/rest/_settings?limit=1"
```

The exchanged token carries the same `"role": "authenticated"` claim, so PostgREST
treats it exactly like a browser token.

### Key rotation

The idp rotates its signing key every `jwt.rotationInterval` (90 days) and keeps
the retired one published for the grace period. PostgREST reads its keys from a
**file fetched once at startup**, so after a rotation run **`./jwks-refresh.sh`**
(see [above](#the-jwks-fetch-service--why-it-exists)) — or `idp rotate-keys`
followed by it, to rotate on demand:

```bash
docker compose exec idp idp rotate-keys
./jwks-refresh.sh
```

### Using a different issuer

The idp is the default, not a requirement. To point the stack at your own IdP,
set in `.env`:

- `VITE_OAUTH_CONFIG` — its discovery URL;
- `VITE_OAUTH_CLIENT_ID` — a public client registered there, whose redirect URI is
  `<your front door>/oauth2_callback`;
- `VITE_OAUTH_AUDIENCE` — the API audience it expects (its issuer URL, if it has
  no separate one);
- `JWKS_URL=` — **empty**, so `jwks-fetch` derives the keys from that discovery
  document.

Your issuer must mint `"role": "authenticated"` into its access tokens. The `idp`
service keeps running (nothing points at it); remove it from the compose file if
you want it gone.

## Management scripts

Thin wrappers over `docker compose` in this repo (project `semantius`);
each has a `.sh` (bash) and `.cmd` (Windows) form.

| Script | Does | `docker compose` |
|---|---|---|
| `create` | **from scratch**: wipe the volumes, pull the DB image, (re)create all containers and start them — a **fresh database** (runs `setup-env` when `.env` is missing). Prompts when a volume exists; `-y` skips. A bare argument pins the tag | `down -v` + `up -d --force-recreate --remove-orphans` |
| `up` | re-pull the image and recreate the **containers**, **keeping the database** — for compose/`.env`/`Caddyfile`/`idp-config` changes. See [`create` vs `up`](#create-vs-up--a-fresh-container-is-not-a-fresh-database) | `up -d --force-recreate --remove-orphans` |
| `setup-env` | write `.env` from `.env.example` with a freshly generated `IDP_SECRET` and database passwords. Called by `create`/`up` when `.env` is missing; **never touches an existing `.env`**. See [the three per-installation secrets](#the-three-per-installation-secrets) | — |
| `start` | start the existing (stopped) containers | `start` |
| `stop` | stop containers, keep them + volumes | `stop` |
| `status` | container status | `ps -a` |
| `destroy` | remove containers, network, and **both volumes** (keeps the image; confirm prompt). The inverse of `create` | `down -v` |
| `jwks-refresh` | re-fetch the issuer JWKS + restart PostgREST to pick up rotated keys (see [Key rotation](#the-jwks-fetch-service--why-it-exists)) | `run --rm jwks-fetch` + `restart postgrest` |
| `dokploy-build` | regenerate the [`dokploy/`](#dokploy-one-click-template) blueprint from `docker-compose.yml` + `Caddyfile` + `idp-config/*.jsonc` + `variants/dokploy/` (needs Node; takes a variant name, default `dokploy`) | — |

`create` and `up` also take **`--no-pull`**, which runs whatever
`ghcr.io/semantius/postgres` tag is already present locally instead of pulling —
for testing an image you built yourself from
[semantius/semantius](https://github.com/semantius/semantius).

> **Windows:** `start` is a `cmd.exe` builtin, so invoke the script explicitly —
> `.\start.cmd` (bash: `./start.sh`).

## Dokploy one-click template

[`dokploy/`](dokploy/) is a **Dokploy blueprint** — the deployment variant of this
same stack, ready to drop into a Dokploy templates gallery.

```bash
npm install            # once — the generator's only dependency is `yaml`
./dokploy-build.sh     # from the repo root (Windows: dokploy-build.cmd)
```

It is **generated** from `docker-compose.yml` + `Caddyfile` +
`idp-config/*.jsonc` + [`variants/dokploy/`](variants/dokploy/) (that variant's
own `template.toml` and `meta.json`) by
[`scripts/dokploy-build.mjs`](scripts/dokploy-build.mjs) — which the script above
is a thin wrapper around (it needs Node) — and **committed**. Never hand-edit
anything under `dokploy/` — change the sources and regenerate. The builder takes
the variant name as an argument (default `dokploy`), so a second deployment
variant is a directory under `variants/`, not a fork of the script. The
transform:

- **strips every `ports:`** — a blueprint publishes nothing; Dokploy's Traefik
  routes to a service by name;
- **strips every `container_name:`** — fixed names collide across deployments;
- **embeds every bind-mounted file** — the `Caddyfile` and each
  `idp-config/*.jsonc` (discovered, not listed) — in a top-level `configs:` block
  with inline `content:`, so the blueprint needs no files beside it
  (`mounts = []` in `template.toml`). `$` is escaped as `$$` there so compose
  leaves Caddy's own `{$SITE_ADDRESS::80}` and the idp's `${env:…}` placeholders
  alone — each is resolved by its own reader;
- **drops `read_only:` from a service that gains such a config** — compose
  delivers an inline `content:` config by *writing it into* the container
  filesystem and refuses outright on a read-only one. That costs the `idp` its
  `read_only` in the blueprint and nothing else: `cap_drop`, `no-new-privileges`
  and the tmpfs survive;
- **validates the result** and fails loudly: no leftover ports, container names,
  custom networks or bind mounts; no read-only service carrying an inline config;
  every embedded file must round-trip back to its source and be mounted at the
  path its service expects; every `${VAR:?…}` the compose requires must be
  supplied by `template.toml`; the `[[config.domains]]` service must exist.

| File | What it is |
|---|---|
| `dokploy/docker-compose.yml` | the stack, portless, with the Caddyfile and the idp config embedded |
| `dokploy/template.toml` | copied from `variants/dokploy/`: Dokploy variables (`${domain}`, generated passwords, a generated `IDP_SECRET`), the env written to the deployment's `.env`, and the domain → `semantius`:80 mapping |
| `dokploy/meta.json` | copied from `variants/dokploy/` — gallery card: id, name, description, logo, links, tags |
| `dokploy/import.base64.txt` | the compose **and** `template.toml` as one base64 string, to paste into Dokploy's **Import** box — the only path in a stock instance that runs `template.toml` without publishing a gallery |

The generated env wires the **bundled issuer** to the deployment
(`IDP_BASE_URL=https://${main_domain}/idp`, a per-deployment `IDP_SECRET`), so a
one-click deploy has a complete auth story: visit `/idp` once and the first
administrator is created. It also turns on the per-request issuer
(`IDP_DYNAMIC_ISSUER=true` — safe under Dokploy's Traefik, see
[Serving more than one domain](#serving-more-than-one-domain-idp_dynamic_issuer))
and templates the SPA's redirect URIs on the request host
(`PUBLIC_WEB_ORIGIN=https://{host}`), so a domain attached **after** deploy in
Dokploy's UI works immediately — discovery, sign-in, the SPA and the API all
follow it. The one thing that stays on the deploy-time domain is **e-mail
links**: update `IDP_BASE_URL` once after attaching your real domain. It also
loads the Northwind demo module (`NWIND=TRUE`) — drop that line for an empty
database.

**Publishing it**, either way:

- fork [github.com/Dokploy/templates](https://github.com/Dokploy/templates) and
  copy the folder to `blueprints/semantius/` (add `logo.svg` — the build prints a
  reminder while it is missing from the repo root), then point your instance at
  the fork as a custom templates repo;
- or, in any instance: **Create Service → Advanced → Import**, and paste the
  contents of [`dokploy/import.base64.txt`](dokploy/import.base64.txt). Dokploy
  shows you the resolved compose, env, mounts and domains before you hit Deploy.

> **`template.toml` runs on the template paths only.** A compose service whose
> source is **Raw** (pasted YAML) or **Git** ignores it — Dokploy reads just the
> compose file at the configured path, so `${domain}`, `${password:32}` and
> `${password:64}` are never expanded and nothing writes the deployment's `.env`.
> On those paths you fill the **Environment** tab yourself; `POSTGRES_PASSWORD`,
> `IDP_SECRET` and `SEMANTIUS_AUTHENTICATOR_PASSWORD` have no defaults in the
> blueprint and the deploy fails at interpolation without them.

The target server needs **docker compose ≥ 2.23.1** (inline `configs.content`).

## Using the CLI against this stack

The Semantius CLI lives in
[semantius/semantius](https://github.com/semantius/semantius); that repo ships an
[`.env.pgrest`](https://github.com/semantius/semantius/blob/main/.env.pgrest)
profile pointing it at this stack on port 5434:

```bash
deno task connect --env pgrest                 # test the DBA connection
deno task migrate --apps test --env pgrest     # deploy more apps on top of _core
```

`_core` is already installed (by the extension), so `migrate` only deploys the
apps you name. After each migration the CLI fires `NOTIFY pgrst, 'reload schema'`,
which the running PostgREST picks up automatically (`PGRST_DB_CHANNEL_ENABLED=true`).

> ⚠️ **Check your secrets are generated ones.** `./setup-env.sh` writes them
> when it creates `.env`, and `up`/`create` call it — but a `.env` copied from
> `.env.example` by hand carries dev defaults. See
> [The three per-installation secrets](#the-three-per-installation-secrets);
> `IDP_SECRET` in particular has to be right *before* first boot.

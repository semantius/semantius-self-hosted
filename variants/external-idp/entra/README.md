# Microsoft Entra ID as the issuer

One worked example of the `external-idp/` variant. Everything here is Entra —
the variant itself is issuer-agnostic, and the root
[README](../../../README.md#external-identity-provider-external-idp) describes
what any issuer must provide.

Verified against a live tenant on 2026-09-16: the tokens, the claims, the error
codes and the setup steps below are what Entra actually does, not what it ought
to do.

## Read this first

**Two things outside this repository have to be in place.**

1. **A database image that accepts Entra's role claim.** Entra cannot emit a
   `role` claim — `role` and `roles` are both in its *restricted claim set*, so
   no claims-mapping policy can produce one. An app role named `authenticated`
   arrives as `"roles": ["authenticated"]` instead. `rbac.uid()` reads that
   array when no `role` claim exists; a `pg_semantius` release **older than that
   change** rejects every request with error `90002` no matter how the rest is
   configured. Pin `SEMANTIUS_DB_VERSION` to a release that has it.
2. **An admin SPA that survives Entra's userinfo endpoint.** Entra's discovery
   document advertises `https://graph.microsoft.com/oidc/userinfo`, and a token
   issued for *your* API is refused there. The SPA calls it after sign-in and
   turns the failure into a blocking error page. Until the app treats userinfo
   as optional, sign-in completes and then stops on that screen.

What *does* work, confirmed end to end: discovery, PKCE, the scope, the
`resource` parameter the SPA sends, the JWKS download, and a token carrying
`roles`, `sub`, `email`, `name`, `given_name` and `family_name` — everything
`get_userinfo()` needs to create the user row.

## The script

```powershell
az login --tenant <your-tenant>.onmicrosoft.com --allow-no-subscriptions
./setup-entra.ps1 -FrontDoorUrl https://semantius.example.com
```

`--allow-no-subscriptions` matters: a Microsoft 365 tenant usually carries no
Azure subscription, and without the flag `az login` ends in *"No subscriptions
found"* and leaves you signed out. App registrations live in Entra ID and need
no subscription at all.

The script creates the three registrations below, pre-authorizes both clients,
assigns the app role to the account you ran it as, and writes the values into
`../.env`. It is idempotent — each registration is looked up by display name
first — and it refuses to touch an `.env` that already has a
`VITE_OAUTH_CLIENT_ID`. `-ProbeToken` prints a real decoded token at the end,
which is the fastest way to see what your tenant actually emits.

Undo any of it with `az ad app delete --id <appId>`.

## Three registrations, two of them clients

| Registration | What it is | Appears in `.env` as |
|---|---|---|
| **Semantius API** | the **resource**. Tokens are issued *for* it, so it owns `aud`, the `access_as_user` scope and the app role `authenticated`. Nothing ever signs in as it. | `PGRST_JWT_AUD`, and the `api://…` prefix inside `VITE_OAUTH_SCOPE` / `VITE_OAUTH_AUDIENCE` |
| **Semantius App** | the SPA **client** | `VITE_OAUTH_CLIENT_ID` |
| **Semantius CLI** | the `semantius-cli` **client** | nothing — a comment only, see [The CLI](#the-cli) |

The bundled idp needs only the two clients, because its audience is a plain
config string (`semantius://api`). Entra insists the audience be a real app
registration before it will mint a token for it. That third registration is the
price of Entra, not a third client.

## Doing it by hand

The script does exactly this, and the portal is the place to check its work.

1. **The API.** App registrations → New registration, single tenant. Then:
   - *Expose an API* → Application ID URI `api://<client-id>` → Add a scope
     `access_as_user`, admin consent only.
   - *App roles* → New app role `authenticated`, value **exactly**
     `authenticated`, allowed member type *Users/Groups*. This value is what
     PostgREST and `rbac.uid()` read; it is not free-form.
   - *Manifest* → `requestedAccessTokenVersion: 2`. Without it you get v1
     tokens, whose `aud` is the `api://…` URI rather than the GUID.
   - *Token configuration* → add optional claims **email**, **given_name**,
     **family_name** to the *access* token. `get_userinfo()` reads those three
     plus `name`; without them the user row is created with a null email, and
     email is the column the admin UI labels users by.
2. **The SPA.** New registration → Authentication → Add a platform →
   **Single-page application**, redirect URI `https://<front door>/oauth2_callback`.
   The platform choice is load-bearing: a Web or public-client redirect URI is
   refused at redemption with `AADSTS9002326`, because the SPA redeems its code
   cross-origin. Then API permissions → the API's `access_as_user`.
3. **The CLI.** New registration → Authentication → Mobile and desktop
   applications, redirect URIs `http://127.0.0.1:53682/callback`, `53683`,
   `53684`; *Allow public client flows* on. Same API permission.
4. **Skip consent** by pre-authorizing instead: on the API, *Expose an API* →
   *Add a client application* for the SPA and the CLI. Owning the registrations
   is then enough; no directory-wide admin consent.
5. **Assign users.** Enterprise applications → *Semantius API* → Users and
   groups → add the people who may use the stack, with the `authenticated` role.

## Stack values

```ini
VITE_OAUTH_CONFIG=https://login.microsoftonline.com/<tenant-id>/v2.0/.well-known/openid-configuration
VITE_OAUTH_CLIENT_ID=<SPA client id>
VITE_OAUTH_SCOPE=openid profile email offline_access api://<API client id>/access_as_user
VITE_OAUTH_AUDIENCE=api://<API client id>
PGRST_JWT_AUD=<API client id>
PGRST_JWT_ROLE_CLAIM_KEY=.roles[0]
JWKS_URL=
VITE_BACKEND_TYPE=custom
VITE_UI_CUSTOMIZER={"user":{"menu":[{"title":"Microsoft account","url":"https://myaccount.microsoft.com/","target":"newtab"}]}}
```

Two of those look like one variable and are not:

- **`VITE_OAUTH_AUDIENCE`** is what the SPA *asks for* — the RFC 8707 `resource`
  parameter. Entra accepts it as long as it matches the resource of the
  requested scope, so it must be the `api://…` form. A mismatch is
  `AADSTS9010010 invalid_target`.
- **`PGRST_JWT_AUD`** is what the token *carries*: for v2 tokens, the bare GUID.

**`PGRST_JWT_AUD` is not optional here.** Entra signs every tenant's tokens with
the same keys, and neither PostgREST nor the database checks `iss`. Without the
audience pinned, a token minted in *any* Entra tenant — by anyone who defines an
app role called `authenticated` — validates against the JWKS this stack
downloads. On an empty database that token would also win the first-administrator
election. Pinning the audience to your own single-tenant API registration is
what closes that. `_settings.jwt_aud` enforces the same check inside the
database, for callers that reach Postgres directly rather than through PostgREST.

`VITE_OAUTH_SCOPE` must name the API scope. Without it Entra issues a Microsoft
Graph token, whose signature this stack cannot verify — Graph tokens are not
meant for anyone but Graph. `offline_access` is what gets a refresh token;
without it every expiry becomes a full page redirect.

`JWKS_URL` stays empty so `jwks-fetch` derives the keys from the discovery
document. That works unchanged against Entra.

### The user menu

`VITE_BACKEND_TYPE=self_hosted` renders `/idp/account` and `/idp/admin`, which
do not exist here — and if the bundled idp happens to still be running
somewhere, those links are worse than missing: they open a *second* identity
with its own session cookie, showing a different user than the one signed in.
So the variant uses `custom` with its own menu.

The entry replacing them is Microsoft's **My Account** portal,
`https://myaccount.microsoft.com/` — display name, contact details, security
info, password, devices, recent sign-ins. That link matters more than it looks:
with an external issuer this stack no longer owns the user's name or e-mail.
The claims come from Entra, and `upsert_user_from_jwt` copies them into the user
row at each sign-in, so My Account is the only place they can be changed. Change
a name there, sign in again, and the row follows.

Nothing discovers that URL — OIDC metadata has no field for "where the user
edits their profile" — so it is a constant per issuer, which is why it lives in
the menu JSON rather than in the generator.

Two optional extras, same shape:

```json
{"title":"Security info","url":"https://mysignins.microsoft.com/security-info","target":"newtab"}
{"title":"My apps","url":"https://myapps.microsoft.com/","target":"newtab"}
```

A user signed in to several tenants may land in the wrong one; appending
`?tenantId=<your tenant id>` is the usual remedy, though Microsoft does not
document that parameter — test it before shipping it to your users.

## Users, roles and the first administrator

- The **app role is the gate.** A user without it gets a token with no `roles`
  claim, PostgREST maps the request to `anon`, and the database is never
  reached.
- The **user row is created on first sign-in**, by `get_userinfo()`, keyed on
  the token's `sub`. Nothing has to be provisioned in advance.
- `sub` is stable per *resource*, not per client: the SPA and the CLI produce
  the same `sub` for the same person, so both map to one user row. It is **not**
  the `oid`, and the id token's `sub` is a different value again — that one
  belongs to the client and must never be used as an identity here.
- On a **fresh database** the first person to sign in becomes Administrator.
  Everyone after that gets the User role, which shows no modules until an
  administrator grants more. If the database was previously used with the
  bundled idp, an idp account already holds Administrator, so the first Entra
  user does *not* get it — grant it in the SPA, or by SQL.

## Key rotation

`jwks-fetch` downloads the keys **once per start**. Entra rotates its signing
keys and publishes new ones ahead of use, so a stale file eventually rejects
every token. This folder ships no helper scripts, so refresh it with:

```bash
docker compose run --rm jwks-fetch
docker compose restart postgrest
```

A daily cron entry is the safe default for Entra, which rotates on its own
schedule rather than yours.

## When it goes wrong

| Symptom | Cause |
|---|---|
| `AADSTS9010010 invalid_target` | `VITE_OAUTH_AUDIENCE` doesn't match the resource of `VITE_OAUTH_SCOPE`. Both must name the same `api://…`. |
| `AADSTS9002326` at redemption | The redirect URI is registered as Web or public client instead of **Single-page application**. |
| `AADSTS70008` when redeeming by hand | A code issued to a SPA redirect URI lives about **60 seconds**. Only affects manual testing. |
| Everything 401s as `anon`; no `roles` in the token | The app role isn't assigned — or it was assigned less than a minute ago. Assignments take a moment to reach the token service. |
| `90002 JWT role claim must be authenticated` | The database image predates the `roles`-array support. Pin a newer `SEMANTIUS_DB_VERSION`. |
| Sign-in completes, then "Failed to fetch user information from OAuth provider" | The SPA's userinfo call to Microsoft Graph. See [Read this first](#read-this-first). |
| `90005 JWT audience does not match` | `_settings.jwt_aud` holds a different value than the token's `aud` — for v2 tokens that is the bare GUID, not `api://…`. |

## The CLI

`semantius-cli` is a second public client against the same API. Register it
(the script does), and pass its client id to the CLI on the machine that runs
it — nothing in this stack reads it, and no stack variable carries it. It is
written into `.env` as a comment for reference only. A future `.well-known`
endpoint is meant to hand it out; until then it is a value you copy.

Its tokens carry the same `sub` as the SPA's, so a person signing in through the
CLI lands on the same user row with the same roles.

# Semantius with Microsoft Entra ID

This folder is a complete Semantius stack — PostgreSQL, the HTTP API, the API
docs and the web app behind one front door — with **no identity provider of its
own**. Your Entra tenant signs the tokens; this stack only verifies them.

It will not start until it is configured. Four steps, below.

---

## Before you start

- **Docker**, with `docker compose` v2.
- **An Entra tenant**, and someone allowed to register applications in it
  (the *Application Developer* role or higher). That may not be you — see
  [step 2](#2-register-three-applications-in-entra).
- **For the script only:** PowerShell 7 and the Azure CLI. Everything it does
  can be done in the Entra admin center instead.

Leave `SEMANTIUS_DB_VERSION` and `SEMANTIUS_APP_VERSION` at their default
(`latest`) unless you have a reason to pin. Entra needs recent images: the
database must understand Entra's role claim, and the web app must not depend on
an identity provider's `userinfo` endpoint. Old pins show up as
[`90002`](#when-it-goes-wrong) or a sign-in that ends on an error page.

---

## 1. Create your `.env`

```bash
./setup-env.sh          # Windows: setup-env.cmd
```

It copies `.env.example` and generates the database passwords. Nothing else
writes this file; every later step fills values *into* it.

## 2. Register three applications in Entra

Semantius needs three registrations: one **API** (what tokens are issued *for*),
one **web app** (what users sign in to), and one **CLI** (for `semantius-cli`).

**With the script**, if you have rights in the tenant:

```powershell
az login --tenant yourcompany.onmicrosoft.com --allow-no-subscriptions
./setup-entra.ps1
```

`--allow-no-subscriptions` matters: a Microsoft 365 tenant usually has no Azure
subscription, and without the flag `az login` ends in *"No subscriptions found"*
and leaves you signed out. App registrations live in Entra ID and need no
subscription.

The script asks for your front door URL (the origin people open in the browser),
creates the three registrations, pre-authorizes the clients so nobody has to
click through a consent screen, assigns the app role to *you*, requires that
assignment for every token the API is issued, and writes the values into
`.env`. Re-running it is safe: it looks each registration up by name first, and
refuses to touch an `.env` that is already configured.

**By hand**, or if someone else administers the tenant: follow
[Registering by hand](#registering-by-hand) below. That person can also run
`./setup-entra.ps1 -NoWrite`, which creates the registrations and *prints* the
values instead of writing them, for you to paste into `.env`.

**More than one Semantius in the same tenant** — a CRM and an HRM, or
production and test — gets one set of registrations *each*:

```powershell
./setup-entra.ps1 -NamePrefix "Semantius CRM"
./setup-entra.ps1 -NamePrefix "Semantius HRM"
```

Each prefix is its own API, web app and CLI: its own audience, so a token for
one host is refused by the other; its own **Users and groups** list; its own
*Assignment required* switch; its own Conditional Access scope. The enterprise
application is then called `<prefix> API` wherever this page says *Semantius
API*. One consequence: `sub` is issued per API, so the same person has a
different external id on each host, and user references do not survive copying
data from one host to the other.

Registrations are found by name and reused, so a second host set up with the
*same* prefix would silently join the first — one audience, tokens valid on
both, one access list. The script refuses that when the web app already serves
another origin; `-Shared` overrides it, for replicas of one system that are
meant to share.

## 3. Give people access

In the Entra admin center: **Enterprise applications → Semantius API → Users and
groups** → assign users or groups to the **`authenticated`** app role.
Assigning *groups* needs an Entra ID P1 licence; assigning users works on the
free tier.

This is the gate, and Entra enforces it: the script turns on **Assignment
required** for the API's enterprise application (by hand, it is one more
setting under [The API](#the-api)), so someone without the role is refused at
Microsoft's sign-in page with `AADSTS50105` and never receives a token for
this API. A token that arrives without the role anyway — the switch off, an
old token — is mapped to `anon` and reaches nothing. A newly assigned user's
first token can still miss the claim; the assignment takes about a minute to
reach the token service.

Registered before the switch existed? `./setup-entra.ps1 -NoWrite` turns it on
for an existing registration without touching `.env`, or flip it yourself under
**Enterprise applications → Semantius API → Properties**.

## 4. Start it

```bash
./up.sh                 # Windows: up.cmd      keeps existing data
./create.sh             # Windows: create.cmd  fresh database, deletes existing data
```

Then open your front door (`http://localhost:3000` by default) and sign in.

**On an empty database, the first person to sign in becomes the administrator.**
Everyone after that gets the default role and sees nothing until an
administrator grants them more, under Administration → Users.

---

## What ends up in `.env`

| Variable | What it is |
|---|---|
| `VITE_OAUTH_CONFIG` | `https://login.microsoftonline.com/<tenant id>/v2.0/.well-known/openid-configuration` |
| `VITE_OAUTH_CLIENT_ID` | the **web app** registration's Application (client) ID |
| `VITE_OAUTH_SCOPE` | `openid profile email offline_access api://<API client id>/access_as_user` |
| `VITE_OAUTH_AUDIENCE` | `api://<API client id>` — what the app *asks* tokens to be issued for |
| `PGRST_JWT_AUD` | `<API client id>` — what a token actually *carries*, and what the API requires |

The last two look like one setting and are not. Entra accepts the request form
(`api://…`) and mints tokens whose audience is the bare GUID.

**`PGRST_JWT_AUD` is not optional here.** Entra signs every tenant's tokens with
the same keys, and nothing in this stack checks which tenant a token came from.
Without the audience pinned to your own single-tenant API registration, a token
minted in somebody else's tenant would verify against the keys this stack
downloads.

Everything else Entra needs is already set in `docker-compose.yml`, because it
is the same for every tenant: the `.roles[0]` claim key, the empty `JWKS_URL`
that derives signing keys from the discovery document, the docs route, and an
account menu pointing at Microsoft's My Account page — with an external issuer
that is the only place a user can change their own name and e-mail.

---

## Registering by hand

What the script does, in the Entra admin center.

### The API

**App registrations → New registration**, single tenant. Then:

- **Expose an API** → set the Application ID URI to `api://<client id>` → **Add
  a scope** named `access_as_user`, admin consent only.
- **App roles → Create app role**: display name *Authenticated*, allowed member
  types *Users/Groups*, **value exactly `authenticated`**. That value is what
  the API reads; it is not free text.
- **Manifest** → `"requestedAccessTokenVersion": 2`. Without it you get v1
  tokens, whose audience is the `api://…` URI rather than the GUID.
- **Token configuration** → add the optional claims **email**, **given_name**
  and **family_name** to the *access* token. The user record is created from
  those; without them it has a name but no e-mail.
- **Enterprise applications → Semantius API → Properties → Assignment
  required?** → *Yes*. This is the enterprise application (the service
  principal), not the registration. Without it every user in the tenant can
  obtain a token for the API — one without the role claim, which the stack
  maps to `anon`; with it, Entra refuses the token itself.

### The web app

**New registration → Authentication → Add a platform → Single-page
application**, redirect URI `https://<your front door>/oauth2_callback`.

The platform matters: a *Web* or *Mobile and desktop* redirect URI is refused at
sign-in with `AADSTS9002326`, because the app redeems its code cross-origin.

Then **API permissions** → add the API's `access_as_user` scope.

### The CLI

**New registration → Authentication → Add a platform → Mobile and desktop
applications**, redirect URIs `http://127.0.0.1:53682/callback`, `:53683`,
`:53684`. Turn **Allow public client flows** on. Same API permission.

### Skip the consent screen

On the API registration: **Expose an API → Add a client application**, and add
the web app and the CLI. Owning the registrations is then enough — no
directory-wide admin consent needed.

---

## Key rotation

The signing keys are downloaded **once, when the stack starts**. Entra rotates
its keys, and a stale copy eventually rejects every token. Refresh with:

```bash
docker compose run --rm jwks-fetch
docker compose restart postgrest
```

A daily scheduled run is the safe default, since Entra rotates on its own
timetable rather than yours.

---

## When it goes wrong

| What you see | What it means |
|---|---|
| `AADSTS9010010` | `VITE_OAUTH_AUDIENCE` and `VITE_OAUTH_SCOPE` name different APIs. Both must point at the same `api://…`. |
| `AADSTS9002326` at sign-in | The redirect URI is registered as *Web* or *Mobile and desktop* instead of **Single-page application**. |
| `AADSTS50011` | The redirect URI in Entra does not match the origin people actually open. It is matched exactly, including the port. |
| `AADSTS50105` at sign-in | The user is not assigned to the `authenticated` app role, and the API requires assignment — the intended refusal. Assign them under **Users and groups**. |
| Everything is refused; the token has no `roles` | The user was assigned less than a minute ago — or **Assignment required** is off on the API's enterprise application and the user is not assigned at all. |
| `90002 JWT role claim must be authenticated` | The database image is older than Entra support. Unpin `SEMANTIUS_DB_VERSION`, or pin a newer release. |
| `90005 JWT audience does not match` | `_settings.jwt_aud` in the database holds a different value than the token's audience — for v2 tokens that is the bare GUID, not `api://…`. |
| `AADSTS70008` when redeeming a code by hand | Codes issued to a single-page application live about 60 seconds. Only affects manual testing. |

---

## The CLI

`semantius-cli` is the third registration: a public client against the same API.
Pass its client id to the CLI on the machine that runs it — nothing in this
stack reads it, so the script records it in `.env` as a comment for reference.

Its tokens carry the same subject as the web app's, so signing in through the
CLI lands on the same user record with the same roles.

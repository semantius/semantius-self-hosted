#requires -Version 7
<#
    Registers this stack with Microsoft Entra ID and writes the result into the
    .env beside it — the three applications the stack needs, in one run.

    WHAT IT CREATES (idempotent: every registration is looked up by display name
    before it is created, so a re-run after a failure reuses what exists and
    nothing is ever duplicated or deleted):

      <prefix> API   the RESOURCE. Tokens are issued FOR it, so it owns the
                     `aud` value, the `access_as_user` scope and the app role
                     `authenticated`. Nothing signs in as it.
      <prefix> App   the SPA client. Carries the redirect URI.
      <prefix> CLI   the semantius-cli client. Public, loopback redirect URIs.

    Both clients are PRE-AUTHORIZED on the API's scope, which is what removes
    the admin-consent step: the operator needs to own the app registrations,
    not the directory.

    SIGN IN FIRST. The tenant is either its domain or its GUID:

      az login --tenant contoso.onmicrosoft.com --allow-no-subscriptions
      az login --tenant a3e7448a-0948-4501-a137-127b123f3c59 --allow-no-subscriptions

    --allow-no-subscriptions is needed whenever the tenant carries no Azure
    subscription — the normal case for a Microsoft 365 tenant. Without it the
    login ends in "No subscriptions found" and leaves you signed out, even
    though app registrations live in Entra ID and need no subscription at all.
    `az account show` then reports name "N/A(tenant level account)", which is
    correct and enough for everything here.

    ASSIGNING USERS is the one step left to a directory admin: this script
    assigns the app role to the account it runs as, and nobody else. Everyone
    else gets it under Enterprise applications > <prefix> API > Users and
    groups (assigning GROUPS needs an Entra ID P1 licence; users work on the
    free tier). The API's enterprise application is set to ASSIGNMENT REQUIRED,
    so a user without the role is refused by Entra at sign-in (AADSTS50105)
    and never receives a token for this API. Should one arrive anyway — the
    switch off, an old token — it carries no `roles` claim, which PostgREST
    maps to `anon`: the stack's way of saying "not a user here".

    MORE THAN ONE SEMANTIUS in the tenant — a CRM and an HRM, or production
    and test — gets one set of registrations EACH: give every host its own
    -NamePrefix ("Semantius CRM"). Each prefix is its own API, App and CLI,
    so its own audience (a token for one host is refused by the other), its
    own Users and groups list, its own "Assignment required" switch. Because
    registrations are found by name and REUSED, a second host run with the
    SAME prefix would silently join the first: one audience, tokens valid on
    both, one access list. The script refuses that when the App already
    serves another origin; -Shared overrides it, for replicas of ONE system
    that are meant to share.

    UNDO: az ad app delete --id <appId>   (once per registration)
#>
[CmdletBinding()]
param(
    # The origin the browser really uses. The SPA builds its redirect URI as
    # <origin>/oauth2_callback and Entra matches it EXACTLY. Left out, it is
    # taken from the .env beside it (PUBLIC_WEB_ORIGIN, else WEB_PORT on
    # localhost) and you are asked to confirm it — the value is worth a second
    # look, because a redirect URI that does not match the browser's origin
    # fails at sign-in with AADSTS50011 and nowhere earlier.
    [string]$FrontDoorUrl,
    [string]$NamePrefix = 'Semantius',
    # The .env of the stack this configures — this script sits in it.
    [string]$EnvFile = (Join-Path $PSScriptRoot '.env'),
    # Print the values instead of writing them.
    [switch]$NoWrite,
    # Fetch a token through the Azure CLI afterwards and print its claims.
    [switch]$ProbeToken,
    # This host is one of SEVERAL served by the same registrations — replicas
    # of ONE system — so the App may carry other hosts' redirect URIs. Without
    # it the script refuses to join an App that already serves another origin;
    # a separate system gets its own -NamePrefix instead.
    [switch]$Shared,
    # READ ONLY: print the configuration, check .env against what is really in
    # Entra, change nothing, and exit non-zero when the two disagree. Works
    # whether or not .env is configured — an unconfigured stack is itself a
    # failure. This is what a configured run prints anyway; the switch adds the
    # pass/fail column and the exit code, so it can gate a pipeline.
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# --- reading .env ------------------------------------------------------------
# Two callers: the front-door default (further down, AFTER the stop condition —
# see the note there) and the report, which needs to know what this stack is
# actually pointed at before it can say whether Entra still agrees.
function Get-EnvValue {
    param([string]$File, [string]$Key)
    if (-not (Test-Path $File)) { return $null }
    $line = Get-Content $File | Where-Object { $_ -match "^\s*$([regex]::Escape($Key))\s*=\s*\S" } | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -split '=', 2)[1].Trim().Trim('"').Trim("'")
}

# The Azure CLI's own public client id — pre-authorized on the scope so
# -ProbeToken can mint a real token without a browser.
$AZ_CLI_APP_ID = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
$GRAPH = 'https://graph.microsoft.com/v1.0'

# The three loopback URIs semantius-cli tries, in order — and the value of
# `redirect_uris` in /.well-known/semantius.json, which the Caddyfile states as
# a literal. They are restated here because semantius-idp-config/oauth_clients.jsonc
# — the source of truth for them — configures the BUNDLED idp and is not part of
# this variant at all. Change them in one place, change them in all three.
#
# Declared UP HERE, not at the point of use, because the report checks them too
# and the script's own rule is that this list lives in one place.
$CliRedirectUris = @(
    'http://127.0.0.1:53682/callback'
    'http://127.0.0.1:53683/callback'
    'http://127.0.0.1:53684/callback'
)

function Invoke-Az {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $raw = & az @Arguments -o json
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') failed (exit $LASTEXITCODE)" }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Invoke-GraphPatch {
    param([string]$Url, [hashtable]$Body)
    $file = New-TemporaryFile
    try {
        ($Body | ConvertTo-Json -Depth 20) | Set-Content -Path $file -Encoding utf8
        & az rest --method PATCH --url $Url --headers 'Content-Type=application/json' --body "@$file" -o none
        if ($LASTEXITCODE -ne 0) { throw "PATCH $Url failed (exit $LASTEXITCODE)" }
    } finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
}

function Get-AppByName {
    param([string]$DisplayName)
    $found = Invoke-Az ad app list --display-name $DisplayName --all
    if ($found -and $found.Count -gt 0) { return $found[0] }
    return $null
}

function Confirm-ServicePrincipal {
    param([string]$AppId)
    $sp = Invoke-Az ad sp list --filter "appId eq '$AppId'"
    if ($sp -and $sp.Count -gt 0) { return $sp[0] }
    return (Invoke-Az ad sp create --id $AppId)
}

# --- lookups that tolerate a missing answer ---------------------------------
# `Invoke-Az` throws, which is right for the configuring path: a failed write
# must stop the run. The report needs the opposite — "that app is GONE" is the
# single most useful thing it can tell you, so a non-zero exit is caught and
# turned into $null instead of ending the script.
function Get-AppById {
    param([string]$AppId)
    if ([string]::IsNullOrWhiteSpace($AppId)) { return $null }
    $raw = & az ad app show --id $AppId -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Get-SpByAppId {
    param([string]$AppId)
    if ([string]::IsNullOrWhiteSpace($AppId)) { return $null }
    $raw = & az ad sp list --filter "appId eq '$AppId'" -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
    $sp = $raw | ConvertFrom-Json
    if ($sp -and $sp.Count -gt 0) { return $sp[0] }
    return $null
}

# --- the Entra admin center, deep-linked ------------------------------------
# TENANT-PINNED: the prefix makes a link open in THIS directory whatever the
# browser signed into last, which is the difference between a link that works
# for the operator and one that lands them in their own tenant looking at
# nothing.
#
# ONE ANCHOR PER OBJECT, not one per page. Authentication, Token
# configuration, App roles, Expose an API and Manifest are all a sidebar click
# from Overview, and the deeper route segments are undocumented portal SPA
# routes Microsoft renames from time to time — a link that rots to reach a page
# already in the sidebar is a liability, not a convenience.
# portal.azure.com serves the same routes if you prefer the old portal.
function Get-AppLink {
    param([string]$TenantId, [string]$AppId)
    "https://entra.microsoft.com/$TenantId/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/$AppId/isMSAApp~/false"
}

# The tenant-wide registrations list, printed ONLY when an appId in .env
# resolves to nothing. "What does this tenant actually have, then" is the next
# question in exactly that case, and it is the only case where a list beats the
# direct link this report gives you the rest of the time.
function Get-AppListLink {
    param([string]$TenantId)
    "https://entra.microsoft.com/$TenantId/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"
}

# The enterprise application is a DIFFERENT object with a different id, and the
# one link here that is not a sidebar click away — you reach it via "Managed
# application in local directory" in the registration's Essentials panel, if
# you know the relationship exists. Properties is where assignmentRequired
# lives, which this report advises on; Users and groups is one click from it.
function Get-SpLink {
    param([string]$TenantId, [string]$SpObjectId, [string]$AppId)
    "https://entra.microsoft.com/$TenantId/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Properties/objectId/$SpObjectId/appId/$AppId"
}

# --- the read-only report ---------------------------------------------------
# What a CONFIGURED stack gets instead of the two-line "nothing to do" it used
# to get, and the body of -Verify. Every call it makes is a GET, so it is safe
# to run against a stack somebody depends on.
#
# Registrations are resolved BY THE IDS IN .env, not by display name. The
# question being answered is "is what .env points at still there", and a name
# lookup would quietly find a REPLACEMENT registration and call that a pass.
# The name lookup runs as well, and a disagreement between the two is reported:
# that is what a re-run under a different -NamePrefix, or a hand-deleted and
# re-created app, actually looks like from here.
#
# Returns the number of FAILED checks (advisories excluded), so -Verify can
# exit on it.
function Show-EntraConfig {
    param([string]$EnvFile, [string]$NamePrefix, [switch]$Verify)

    $checks = [System.Collections.Generic.List[object]]::new()
    # Advisory means "worth knowing, not a reason to fail a pipeline" — the
    # assignment gate and the assigned-user count, where the right value is a
    # policy choice rather than a thing that is simply broken.
    function Add-Check {
        param([string]$Name, [bool]$Ok, [string]$Detail, [switch]$Advisory)
        $checks.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail; Advisory = [bool]$Advisory })
    }
    function Write-Field {
        param([string]$Name, $Value, [string]$Color = 'Gray')
        $shown = if ($null -eq $Value -or "$Value" -eq '') { '(empty)' } else { "$Value" }
        Write-Host ("  {0,-22} {1}" -f $Name, $shown) -ForegroundColor $Color
    }

    # .env FIRST, and unconditionally: it is printable without a network, so an
    # offline run still tells you what the stack believes about itself.
    $keys = @('VITE_OAUTH_CONFIG', 'VITE_OAUTH_CLIENT_ID', 'CLI_OAUTH_CLIENT_ID',
              'VITE_OAUTH_AUDIENCE', 'PGRST_JWT_AUD', 'PGRST_JWT_ROLE_CLAIM_KEY',
              'VITE_OAUTH_SCOPE', 'PUBLIC_WEB_ORIGIN', 'WEB_PORT')
    $e = @{}
    foreach ($k in $keys) { $e[$k] = Get-EnvValue $EnvFile $k }

    Write-Host ""
    Write-Host "--- .env ------------------------------------------------------" -ForegroundColor Green
    Write-Field 'file' $EnvFile
    foreach ($k in $keys) { Write-Field $k $e[$k] }

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Host ""
        Write-Host "Azure CLI not found — the values above are all this can show." -ForegroundColor Yellow
        Write-Host "  winget install --exact --id Microsoft.AzureCLI" -ForegroundColor Yellow
        return $(if ($Verify) { 1 } else { 0 })
    }
    $raw = & az account show -o json 2>$null
    $account = if ($LASTEXITCODE -eq 0 -and $raw) { $raw | ConvertFrom-Json } else { $null }
    if (-not $account) {
        Write-Host ""
        Write-Host "Not signed in — the values above are all this can show." -ForegroundColor Yellow
        Write-Host "  az login --tenant <tenant> --allow-no-subscriptions" -ForegroundColor Yellow
        return $(if ($Verify) { 1 } else { 0 })
    }
    $tenantId = $account.tenantId

    Write-Host ""
    Write-Host "--- tenant ----------------------------------------------------" -ForegroundColor Green
    Write-Field 'tenant' $tenantId
    Write-Field 'signed in as' $account.user.name

    # The discovery URL carries the tenant the SPA will really talk to, and
    # docker-compose's jwks-fetch curls it directly to derive the signing keys.
    # A mismatch with the signed-in tenant means everything below describes a
    # DIFFERENT directory than the stack uses — checked first, because nothing
    # after it means much otherwise.
    if ($e['VITE_OAUTH_CONFIG']) {
        $m = [regex]::Match($e['VITE_OAUTH_CONFIG'], '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
        $cfgTenant = if ($m.Success) { $m.Value } else { $null }
        Add-Check 'VITE_OAUTH_CONFIG tenant' ($cfgTenant -eq $tenantId) `
            $(if ($cfgTenant -eq $tenantId) { 'matches the signed-in tenant' }
              elseif ($cfgTenant) { "points at $cfgTenant, but you are signed in to $tenantId" }
              else { 'no tenant guid in the discovery URL' })
    } else {
        Add-Check 'VITE_OAUTH_CONFIG' $false 'empty — jwks-fetch derives the signing keys from it and cannot start'
    }

    # PGRST_JWT_AUD is the API's bare appId; VITE_OAUTH_AUDIENCE is the same id
    # in api:// form. Either identifies the resource, so fall back rather than
    # give up when only one is set.
    $apiId = $e['PGRST_JWT_AUD']
    if (-not $apiId -and $e['VITE_OAUTH_AUDIENCE']) { $apiId = ($e['VITE_OAUTH_AUDIENCE'] -replace '^api://', '') }

    $api = Get-AppById $apiId
    $spa = Get-AppById $e['VITE_OAUTH_CLIENT_ID']
    $cli = Get-AppById $e['CLI_OAUTH_CLIENT_ID']

    # --- the API ------------------------------------------------------------
    Write-Host ""
    Write-Host "--- $NamePrefix API  (the resource tokens are issued FOR) -----" -ForegroundColor Green
    if (-not $api) {
        Write-Host "  GONE — nothing in this tenant has appId $apiId" -ForegroundColor Red
        Write-Host "  what this tenant does have: $(Get-AppListLink $tenantId)" -ForegroundColor DarkCyan
        Add-Check 'PGRST_JWT_AUD' $false "no registration with appId $apiId — deleted, or in another tenant"
    } else {
        $scope   = $api.api.oauth2PermissionScopes | Where-Object { $_.value -eq 'access_as_user' } | Select-Object -First 1
        $role    = $api.appRoles | Where-Object { $_.value -eq 'authenticated' } | Select-Object -First 1
        $claims  = @($api.optionalClaims.accessToken | ForEach-Object { $_.name })
        $preAuth = @($api.api.preAuthorizedApplications | ForEach-Object { $_.appId })
        $apiSp   = Get-SpByAppId $api.appId

        Write-Field 'displayName'    $api.displayName
        Write-Field 'appId'          $api.appId
        Write-Field 'objectId'       $api.id
        Write-Field 'identifierUris' (@($api.identifierUris) -join ', ')
        Write-Field 'tokenVersion'   $api.api.requestedAccessTokenVersion
        Write-Field 'signInAudience' $api.signInAudience
        Write-Field 'scope'          $(if ($scope) { "$($scope.value)  (id $($scope.id), $($scope.type) consent, enabled=$($scope.isEnabled))" } else { $null })
        Write-Field 'appRole'        $(if ($role) { "$($role.value)  (id $($role.id), $(@($role.allowedMemberTypes) -join '/'), enabled=$($role.isEnabled))" } else { $null })
        Write-Field 'optionalClaims' ($claims -join ', ')
        Write-Field 'preAuthorized'  ($preAuth.Count.ToString() + ' client(s)')

        Add-Check 'API registration' $true "$($api.displayName) ($($api.appId))"
        Add-Check 'API tokenVersion' ($api.api.requestedAccessTokenVersion -eq 2) `
            $(if ($api.api.requestedAccessTokenVersion -eq 2) { 'v2 — aud is the bare appId, as PGRST_JWT_AUD expects' }
              else { "v$($api.api.requestedAccessTokenVersion) — aud would be the api:// URI, so PGRST_JWT_AUD can never match" })
        Add-Check 'API signInAudience' ($api.signInAudience -eq 'AzureADMyOrg') `
            $(if ($api.signInAudience -eq 'AzureADMyOrg') { 'single tenant — the audience means something' }
              else { "$($api.signInAudience) — Entra signs every tenant with the same keys, so another tenant could mint this aud" })

        if ($e['VITE_OAUTH_AUDIENCE']) {
            $ok = @($api.identifierUris) -contains $e['VITE_OAUTH_AUDIENCE']
            Add-Check 'VITE_OAUTH_AUDIENCE' $ok `
                $(if ($ok) { "$($e['VITE_OAUTH_AUDIENCE']) is an identifier URI of the API" }
                  else { "$($e['VITE_OAUTH_AUDIENCE']) is not in $(@($api.identifierUris) -join ', ') — sign-in ends on a bare Login Error" })
        }
        if ($e['PGRST_JWT_AUD']) {
            Add-Check 'PGRST_JWT_AUD' ($e['PGRST_JWT_AUD'] -eq $api.appId) `
                $(if ($e['PGRST_JWT_AUD'] -eq $api.appId) { 'equals the API appId, which is what lands in aud' }
                  else { "is $($e['PGRST_JWT_AUD']) but the API appId is $($api.appId) — PostgREST rejects every token" })
        }

        Add-Check 'scope access_as_user' ([bool]$scope -and $scope.isEnabled) `
            $(if ($scope -and $scope.isEnabled) { "exposed and enabled (id $($scope.id))" }
              elseif ($scope) { 'exposed but DISABLED — no token will be issued for it' }
              else { 'not exposed on the API' })
        if ($scope -and $e['VITE_OAUTH_SCOPE']) {
            $want = "api://$($api.appId)/access_as_user"
            $ok = $e['VITE_OAUTH_SCOPE'] -like "*$want*"
            Add-Check 'VITE_OAUTH_SCOPE' $ok `
                $(if ($ok) { "names $want" } else { "does not name $want — Entra may mint a token for something else" })
        }

        Add-Check "app role 'authenticated'" ([bool]$role -and $role.isEnabled -and (@($role.allowedMemberTypes) -contains 'User')) `
            $(if (-not $role) { "not defined — every signed-in user maps to anon" }
              elseif (-not $role.isEnabled) { 'defined but DISABLED' }
              elseif (-not (@($role.allowedMemberTypes) -contains 'User')) { "allowedMemberTypes is $(@($role.allowedMemberTypes) -join '/'), so users cannot hold it" }
              else { "enabled, assignable to users (id $($role.id))" })
        if ($e['PGRST_JWT_ROLE_CLAIM_KEY']) {
            $ok = $e['PGRST_JWT_ROLE_CLAIM_KEY'] -eq '.roles[0]'
            Add-Check 'PGRST_JWT_ROLE_CLAIM_KEY' $ok `
                $(if ($ok) { "reads the roles claim the app role produces" }
                  else { "is $($e['PGRST_JWT_ROLE_CLAIM_KEY']), not .roles[0] — the app role would be ignored" })
        }

        Add-Check 'optional claim email' ($claims -contains 'email') `
            $(if ($claims -contains 'email') { 'present — get_userinfo() can fill the email column' }
              else { 'missing — user rows are created with a null email' })

        if ($apiSp) {
            $assigned = $null
            $rawA = & az rest --method GET --url "$GRAPH/servicePrincipals/$($apiSp.id)/appRoleAssignedTo" -o json 2>$null
            if ($LASTEXITCODE -eq 0 -and $rawA) { $assigned = ($rawA | ConvertFrom-Json).value }
            $names = @($assigned | ForEach-Object { "$($_.principalDisplayName) ($($_.principalType))" })

            Write-Field 'assignmentRequired' $(if ($apiSp.appRoleAssignmentRequired) { 'ON' } else { 'OFF' }) `
                $(if ($apiSp.appRoleAssignmentRequired) { 'Gray' } else { 'Yellow' })
            Write-Field 'assigned'           $(if ($names.Count) { $names -join ', ' } else { 'nobody' })

            # ADVISORY, both of them: a stack with the gate open is not broken
            # — PostgREST still maps a role-less token to anon — so this must
            # not fail a pipeline. It is reported because the script's own
            # docstring claims the gate is closed, and OFF is how that claim
            # goes stale without anyone noticing.
            Add-Check 'assignmentRequired' ([bool]$apiSp.appRoleAssignmentRequired) `
                $(if ($apiSp.appRoleAssignmentRequired) { 'ON — Entra refuses a token to an unassigned user (AADSTS50105)' }
                  else { 'OFF — every user in the tenant can get a token for this API; they arrive as anon' }) -Advisory
            Add-Check 'role assignments' ($names.Count -gt 0) `
                $(if ($names.Count) { "$($names.Count) principal(s) hold 'authenticated'" } else { "nobody holds 'authenticated' — every sign-in lands as anon" }) -Advisory
        } else {
            Add-Check 'API service principal' $false 'no enterprise application — the API cannot be assigned or consented to'
        }

        Write-Host "  links" -ForegroundColor DarkCyan
        Write-Host ("    {0,-20} {1}" -f 'overview',       (Get-AppLink $tenantId $api.appId)) -ForegroundColor DarkCyan
        if ($apiSp) {
            Write-Host ("    {0,-20} {1}" -f 'enterprise app', (Get-SpLink $tenantId $apiSp.id $api.appId)) -ForegroundColor DarkCyan
        }
    }

    # --- the SPA ------------------------------------------------------------
    Write-Host ""
    Write-Host "--- $NamePrefix App  (the SPA users sign in to) ---------------" -ForegroundColor Green
    if (-not $spa) {
        Write-Host "  GONE — nothing in this tenant has appId $($e['VITE_OAUTH_CLIENT_ID'])" -ForegroundColor Red
        Write-Host "  what this tenant does have: $(Get-AppListLink $tenantId)" -ForegroundColor DarkCyan
        Add-Check 'VITE_OAUTH_CLIENT_ID' $false "no registration with appId $($e['VITE_OAUTH_CLIENT_ID']) — deleted, or in another tenant"
    } else {
        $spaUris = @($spa.spa.redirectUris)
        Write-Field 'displayName'      $spa.displayName
        Write-Field 'appId'            $spa.appId
        Write-Field 'objectId'         $spa.id
        Write-Field 'signInAudience'   $spa.signInAudience
        Write-Field 'spa.redirectUris' ($spaUris -join ', ')
        foreach ($p in @('web', 'publicClient')) {
            $other = @($spa.$p.redirectUris)
            if ($other.Count) { Write-Field "$p.redirectUris" ($other -join ', ') 'Yellow' }
        }

        Add-Check 'SPA registration' $true "$($spa.displayName) ($($spa.appId))"

        # The origin the browser really uses, from .env — the same precedence
        # the front-door default uses further down.
        $origin = $null
        if ($e['PUBLIC_WEB_ORIGIN'] -and $e['PUBLIC_WEB_ORIGIN'] -notmatch '\{host\}') { $origin = $e['PUBLIC_WEB_ORIGIN'].TrimEnd('/') }
        elseif ($e['WEB_PORT']) { $origin = "http://localhost:$($e['WEB_PORT'])" }
        if ($origin) {
            $want = "$origin/oauth2_callback"
            $ok = $spaUris -contains $want
            Add-Check 'SPA redirect URI' $ok `
                $(if ($ok) { "$want is registered" } else { "$want is NOT registered — sign-in fails with AADSTS50011" })

            # The trap that makes a re-run throw: a second origin on the App
            # means this host would SHARE registrations with another, and the
            # guard refuses that without -Shared. Advisory, because sharing is
            # legitimate for replicas of one system — it just has to be meant.
            $others = @($spaUris | Where-Object { $_ } |
                ForEach-Object { ([uri]$_).GetLeftPart([UriPartial]::Authority) } |
                Where-Object { $_ -ne ([uri]$origin).GetLeftPart([UriPartial]::Authority) } | Select-Object -Unique)
            if ($others.Count) {
                Add-Check 'SPA extra origins' $false `
                    "also serves $($others -join ', ') — a re-run needs -Shared, or another -NamePrefix" -Advisory
            }
        }

        # Entra refuses cross-origin token redemption for the web and public
        # platforms (AADSTS9002326), and that is how the SPA redeems its code.
        Add-Check 'SPA platform' ($spaUris.Count -gt 0) `
            $(if ($spaUris.Count) { 'redirect URIs are on the single-page application platform' }
              else { 'no SPA-platform redirect URIs — code redemption fails with AADSTS9002326' })

        if ($api) {
            $ok = @($api.api.preAuthorizedApplications | ForEach-Object { $_.appId }) -contains $spa.appId
            Add-Check 'SPA pre-authorized' $ok `
                $(if ($ok) { 'on the API scope — no consent screen' } else { 'NOT on the API scope — users meet a consent prompt' })
        }

        Write-Host "  links" -ForegroundColor DarkCyan
        Write-Host ("    {0,-20} {1}" -f 'overview',       (Get-AppLink $tenantId $spa.appId)) -ForegroundColor DarkCyan
    }

    # --- the CLI ------------------------------------------------------------
    Write-Host ""
    Write-Host "--- $NamePrefix CLI  (semantius-cli) --------------------------" -ForegroundColor Green
    if (-not $cli) {
        Write-Host "  GONE — nothing in this tenant has appId $($e['CLI_OAUTH_CLIENT_ID'])" -ForegroundColor Red
        Write-Host "  what this tenant does have: $(Get-AppListLink $tenantId)" -ForegroundColor DarkCyan
        Add-Check 'CLI_OAUTH_CLIENT_ID' $false "no registration with appId $($e['CLI_OAUTH_CLIENT_ID']) — deleted, or in another tenant"
    } else {
        $cliUris = @($cli.publicClient.redirectUris)
        Write-Field 'displayName'  $cli.displayName
        Write-Field 'appId'        $cli.appId
        Write-Field 'objectId'     $cli.id
        Write-Field 'publicClient' ($cliUris -join ', ')
        Write-Field 'isFallbackPublicClient' $cli.isFallbackPublicClient

        Add-Check 'CLI registration' $true "$($cli.displayName) ($($cli.appId))"

        # Entra has no RFC 8252 7.3 loopback carve-out — it matches the PORT
        # too — so every address the CLI might bind has to be there.
        $missing = @($CliRedirectUris | Where-Object { $cliUris -notcontains $_ })
        Add-Check 'CLI redirect URIs' ($missing.Count -eq 0) `
            $(if ($missing.Count -eq 0) { "all $($CliRedirectUris.Count) loopback ports registered" }
              else { "missing $($missing -join ', ') — a login that binds that port fails" })
        Add-Check 'CLI public client' ([bool]$cli.isFallbackPublicClient) `
            $(if ($cli.isFallbackPublicClient) { 'isFallbackPublicClient is true' }
              else { 'isFallbackPublicClient is false — Entra refuses the public-client code redemption' })
        if ($api) {
            $ok = @($api.api.preAuthorizedApplications | ForEach-Object { $_.appId }) -contains $cli.appId
            Add-Check 'CLI pre-authorized' $ok `
                $(if ($ok) { 'on the API scope — no consent screen' } else { 'NOT on the API scope — the CLI login meets a consent prompt' })
        }

        Write-Host "  links" -ForegroundColor DarkCyan
        Write-Host ("    {0,-20} {1}" -f 'overview',       (Get-AppLink $tenantId $cli.appId)) -ForegroundColor DarkCyan
    }

    # --- does .env agree with the registrations named $NamePrefix? -----------
    # The one thing an id lookup cannot catch: .env pointing at a perfectly
    # healthy app that is no longer the one this prefix builds. A second run
    # with a different -NamePrefix leaves exactly this state.
    foreach ($pair in @(@{ n = "$NamePrefix API"; got = $api }, @{ n = "$NamePrefix App"; got = $spa }, @{ n = "$NamePrefix CLI"; got = $cli })) {
        $byName = $null
        $rawN = & az ad app list --display-name $pair.n --all -o json 2>$null
        if ($LASTEXITCODE -eq 0 -and $rawN) { $byName = ($rawN | ConvertFrom-Json) | Select-Object -First 1 }
        if ($byName -and $pair.got -and $byName.appId -ne $pair.got.appId) {
            Add-Check "'$($pair.n)' by name" $false `
                "is $($byName.appId), but .env points at $($pair.got.appId) — two sets of registrations exist" -Advisory
        }
    }

    # --- the verdict --------------------------------------------------------
    $failed = @($checks | Where-Object { -not $_.Ok -and -not $_.Advisory })
    $warned = @($checks | Where-Object { -not $_.Ok -and $_.Advisory })

    if ($Verify) {
        Write-Host ""
        Write-Host "--- verify  (.env against Entra) ------------------------------" -ForegroundColor Green
        foreach ($c in $checks) {
            $tag, $color =
                if ($c.Ok) { 'PASS', 'DarkGray' }
                elseif ($c.Advisory) { 'WARN', 'Yellow' }
                else { 'FAIL', 'Red' }
            Write-Host ("  {0}  {1,-26} {2}" -f $tag, $c.Name, $c.Detail) -ForegroundColor $color
        }
        Write-Host ""
        if ($failed.Count) {
            Write-Host "$($failed.Count) check(s) failed, $($warned.Count) advisory." -ForegroundColor Red
        } else {
            Write-Host "All checks passed$(if ($warned.Count) { ", $($warned.Count) advisory" })." -ForegroundColor Green
        }
    } elseif ($failed.Count -or $warned.Count) {
        # Not -Verify, so the pass/fail column is not printed — but silently
        # sitting on a broken audience while showing a tidy report would be
        # worse than noise. Name the count and the switch that explains it.
        Write-Host ""
        Write-Host "$($failed.Count) problem(s) and $($warned.Count) advisory — run with -Verify for the detail." -ForegroundColor Yellow
    }

    return $failed.Count
}

# --- stop condition, before anything is created -----------------------------
# "Already configured" is the app client id having a value: that is the one
# variable the stack cannot start without, and the one this script exists to
# produce. An .env that has it is somebody's working configuration, and a
# second run must not quietly point it at new registrations.
#
# THIS SITS ABOVE THE FRONT-DOOR PROMPT ON PURPOSE. It used to sit sixty lines
# below it, so a configured stack was asked to confirm an origin, had the answer
# validated, and was then told "nothing to do" — a question whose answer was
# already destined for the bin. It depends on nothing but the file, so it goes
# first, and what it prints is the configuration rather than two lines about
# having declined to look at it.
if ($Verify) {
    exit (Show-EntraConfig -EnvFile $EnvFile -NamePrefix $NamePrefix -Verify)
}
if (-not $NoWrite -and (Test-Path $EnvFile) -and (Get-EnvValue $EnvFile 'VITE_OAUTH_CLIENT_ID')) {
    Write-Host "$EnvFile is already configured — nothing to change. Here is what it points at:" -ForegroundColor Yellow
    # Deliberately NOT propagated: this run was a no-op by design and used to
    # exit 0 without needing az at all. Making it fail now, on a box with no
    # Azure CLI or no login, would break a working invocation over a
    # diagnostic. -Verify is the one that carries an exit code.
    Show-EntraConfig -EnvFile $EnvFile -NamePrefix $NamePrefix | Out-Null
    Write-Host ""
    Write-Host "To CHECK it rather than read it:  .\setup-entra.ps1 -Verify" -ForegroundColor Yellow
    Write-Host "To re-apply the registrations, clear VITE_OAUTH_CLIENT_ID in .env first." -ForegroundColor Yellow
    exit 0
}

# --- where the browser reaches this stack -----------------------------------
# Only reached when there is something to configure — see the stop condition.
if (-not $FrontDoorUrl) {
    $envDir = Split-Path $EnvFile -Parent
    $suggested = $null
    foreach ($candidate in @($EnvFile, (Join-Path $envDir '.env.example'))) {
        $origin = Get-EnvValue $candidate 'PUBLIC_WEB_ORIGIN'
        if ($origin -and $origin -notmatch '\{host\}') { $suggested = $origin.TrimEnd('/'); break }
        $port = Get-EnvValue $candidate 'WEB_PORT'
        if ($port) { $suggested = "http://localhost:$port"; break }
    }
    if (-not $suggested) { $suggested = 'http://localhost:3000' }

    Write-Host "The origin the browser uses to reach this stack." -ForegroundColor Cyan
    Write-Host "The SPA's redirect URI becomes <origin>/oauth2_callback, matched EXACTLY by Entra."
    $answer = Read-Host "Front door URL [$suggested]"
    $FrontDoorUrl = if ([string]::IsNullOrWhiteSpace($answer)) { $suggested } else { $answer.Trim() }
}

if ($FrontDoorUrl -notmatch '^https?://') {
    throw "FrontDoorUrl must start with http:// or https:// — got '$FrontDoorUrl'"
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found. Install it (winget install --exact --id Microsoft.AzureCLI) and open a new shell."
}

$account = Invoke-Az account show
$tenantId = $account.tenantId
Write-Host "Tenant:     $tenantId  ($($account.user.name))" -ForegroundColor Cyan
Write-Host "Front door: $FrontDoorUrl" -ForegroundColor Cyan
Write-Host ""

# --- 1. the API registration (the resource) ---------------------------------
$apiName = "$NamePrefix API"
Write-Host "[1/3] $apiName" -ForegroundColor Cyan
$api = Get-AppByName $apiName
if (-not $api) {
    # requestedAccessTokenVersion 2 is what makes `aud` the client-id GUID and
    # the claims v2. Single tenant is load-bearing: Entra signs every tenant's
    # tokens with the SAME keys, so an audience only means something if no
    # other tenant can mint a token carrying it.
    $api = Invoke-Az ad app create --display-name $apiName `
        --sign-in-audience AzureADMyOrg --requested-access-token-version 2
    Write-Host "  created $($api.appId)" -ForegroundColor DarkGray
} else {
    Write-Host "  exists $($api.appId)" -ForegroundColor DarkGray
}
$apiAppId = $api.appId
$apiObjId = $api.id

if (-not $api.identifierUris -or $api.identifierUris.Count -eq 0) {
    Invoke-Az ad app update --id $apiAppId --identifier-uris "api://$apiAppId" | Out-Null
    Write-Host "  identifier URI api://$apiAppId" -ForegroundColor DarkGray
}

# The exposed scope. No az flag for this one, so Graph directly. An existing
# scope keeps its id: the clients' permission grants reference it.
$api = Invoke-Az ad app show --id $apiAppId
$scope = $api.api.oauth2PermissionScopes | Where-Object { $_.value -eq 'access_as_user' } | Select-Object -First 1
if (-not $scope) {
    $scopeId = [guid]::NewGuid().ToString()
    Invoke-GraphPatch "$GRAPH/applications/$apiObjId" @{
        api = @{
            requestedAccessTokenVersion = 2
            oauth2PermissionScopes      = @(@{
                id                      = $scopeId
                value                   = 'access_as_user'
                type                    = 'User'
                isEnabled               = $true
                adminConsentDisplayName = "Access $NamePrefix as the signed-in user"
                adminConsentDescription = "Allows the app to call the $NamePrefix API as the signed-in user."
                userConsentDisplayName  = "Access $NamePrefix on your behalf"
                userConsentDescription  = "Allows the app to call the $NamePrefix API as you."
            })
        }
    }
    Write-Host "  scope access_as_user exposed" -ForegroundColor DarkGray
} else {
    $scopeId = $scope.id
    Write-Host "  scope access_as_user exists" -ForegroundColor DarkGray
}

# The app role. `authenticated` is the value pg_semantius and PostgREST both
# read (PGRST_JWT_ROLE_CLAIM_KEY=.roles[0]); the name is not free-form.
$role = $api.appRoles | Where-Object { $_.value -eq 'authenticated' } | Select-Object -First 1
if (-not $role) {
    $roleId = [guid]::NewGuid().ToString()
    $rolesFile = New-TemporaryFile
    try {
        @(@{
            id                 = $roleId
            allowedMemberTypes = @('User')
            value              = 'authenticated'
            displayName        = 'Authenticated'
            description        = "Signed-in user of the $NamePrefix API (maps to the authenticated database role)."
            isEnabled          = $true
        }) | ConvertTo-Json -Depth 10 -AsArray | Set-Content -Path $rolesFile -Encoding utf8
        Invoke-Az ad app update --id $apiAppId --app-roles "@$rolesFile" | Out-Null
        Write-Host "  app role authenticated defined" -ForegroundColor DarkGray
    } finally { Remove-Item $rolesFile -Force -ErrorAction SilentlyContinue }
} else {
    $roleId = $role.id
    Write-Host "  app role authenticated exists" -ForegroundColor DarkGray
}

# Optional claims, on the API because it is the token's audience. Without
# these the access token carries `name` but no `email`, `given_name` or
# `family_name` — and get_userinfo() reads exactly those four, so the user row
# would be created with a null email, which is the column the admin UI labels
# users by. They still only appear for users whose directory record has them.
$optFile = New-TemporaryFile
try {
    @{
        accessToken = @(
            @{ name = 'email';       essential = $false },
            @{ name = 'xms_edov';    essential = $false },
            @{ name = 'given_name';  essential = $false },
            @{ name = 'family_name'; essential = $false }
        )
        idToken = @(); saml2Token = @()
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $optFile -Encoding utf8
    Invoke-Az ad app update --id $apiAppId --optional-claims "@$optFile" | Out-Null
    Write-Host "  optional claims email, given_name, family_name" -ForegroundColor DarkGray
} finally { Remove-Item $optFile -Force -ErrorAction SilentlyContinue }

$apiSp = Confirm-ServicePrincipal $apiAppId

# --- 2. the SPA registration ------------------------------------------------
$spaName = "$NamePrefix App"
Write-Host "[2/3] $spaName" -ForegroundColor Cyan
$spa = Get-AppByName $spaName
if (-not $spa) {
    $spa = Invoke-Az ad app create --display-name $spaName --sign-in-audience AzureADMyOrg
    Write-Host "  created $($spa.appId)" -ForegroundColor DarkGray
} else {
    Write-Host "  exists $($spa.appId)" -ForegroundColor DarkGray
}
$spaAppId = $spa.appId
$redirectUri = "$($FrontDoorUrl.TrimEnd('/'))/oauth2_callback"

# It must be the SINGLE-PAGE APPLICATION platform, not Web and not public
# client: Entra refuses cross-origin token redemption for the other two
# (AADSTS9002326), and that is how the SPA redeems its code. There is no az
# flag for spa.redirectUris either, so Graph again. Existing URIs are kept.
$spaCurrent = (Invoke-Az ad app show --id $spaAppId).spa.redirectUris

# ANOTHER HOST'S URIs on this App mean this host would JOIN it: one audience,
# tokens valid on every host it serves, one access list. Right for replicas of
# one system, wrong for two systems — so it is refused unless -Shared says it
# is meant; a separate system gets its own -NamePrefix. Compared by ORIGIN
# (scheme, host, port), so a re-run for the same host is silent. Nothing new
# has been created at this point: an App with other URIs means the whole
# triplet already existed, and step 1 only re-applied settings to it.
$hostOrigin = ([uri]$FrontDoorUrl).GetLeftPart([UriPartial]::Authority)
$others = @(@($spaCurrent) | Where-Object { $_ } |
    ForEach-Object { ([uri]$_).GetLeftPart([UriPartial]::Authority) } |
    Where-Object { $_ -ne $hostOrigin } | Select-Object -Unique)
if ($others.Count -gt 0 -and -not $Shared) {
    throw ("'$spaName' already serves $($others -join ', '). This host would share registrations, " +
           "tokens and the access list with it. Pass -NamePrefix '<another name>' to keep the hosts " +
           "separate, or -Shared to join them on purpose.")
}
if ($others.Count -gt 0) {
    Write-Host "  sharing with $($others -join ', ') (-Shared)" -ForegroundColor Yellow
}

$uris = @($spaCurrent) + $redirectUri | Where-Object { $_ } | Select-Object -Unique
Invoke-GraphPatch "$GRAPH/applications/$($spa.id)" @{ spa = @{ redirectUris = @($uris) } }
Write-Host "  SPA redirect URI $redirectUri" -ForegroundColor DarkGray

$rraFile = New-TemporaryFile
try {
    @(@{ resourceAppId = $apiAppId; resourceAccess = @(@{ id = $scopeId; type = 'Scope' }) }) |
        ConvertTo-Json -Depth 10 -AsArray | Set-Content -Path $rraFile -Encoding utf8
    Invoke-Az ad app update --id $spaAppId --required-resource-accesses "@$rraFile" | Out-Null
} finally { Remove-Item $rraFile -Force -ErrorAction SilentlyContinue }
Confirm-ServicePrincipal $spaAppId | Out-Null

# --- 3. the CLI registration ------------------------------------------------
$cliName = "$NamePrefix CLI"
Write-Host "[3/3] $cliName" -ForegroundColor Cyan
# $CliRedirectUris — the three loopback URIs semantius-cli tries — is declared
# at the top of this script, because the report checks them too.

$cli = Get-AppByName $cliName
if (-not $cli) {
    $cli = Invoke-Az ad app create --display-name $cliName --sign-in-audience AzureADMyOrg `
        --is-fallback-public-client true `
        --public-client-redirect-uris @CliRedirectUris
    Write-Host "  created $($cli.appId)" -ForegroundColor DarkGray
} else {
    Write-Host "  exists $($cli.appId)" -ForegroundColor DarkGray
}
$cliAppId = $cli.appId

# UNCONDITIONALLY, not only on create. Entra has no RFC 8252 §7.3 loopback
# carve-out — it matches the PORT too — so every address the CLI might bind has
# to be registered, and until now an app that already existed was left exactly
# as it was: a registration made by hand from README.md's portal walkthrough, or
# one predating a change to this list, was never corrected. That is also the
# -NoWrite recovery path, which is precisely when it matters.
#
# `az ad app update` REPLACES the list, so union first — the same way the SPA's
# redirect URI is merged above — and the re-run stays idempotent.
$cliCurrent = (Invoke-Az ad app show --id $cliAppId).publicClient.redirectUris
$cliUris = @(@($cliCurrent) + $CliRedirectUris | Where-Object { $_ } | Select-Object -Unique)
Invoke-Az ad app update --id $cliAppId --public-client-redirect-uris @cliUris | Out-Null
# Also create-only until now. Without it Entra refuses the public-client code
# redemption the CLI does, and an app registered by hand usually lacks it.
Invoke-Az ad app update --id $cliAppId --is-fallback-public-client true | Out-Null
Write-Host "  CLI redirect URIs $($CliRedirectUris -join ', ')" -ForegroundColor DarkGray

Confirm-ServicePrincipal $cliAppId | Out-Null

# --- pre-authorization ------------------------------------------------------
# What removes the admin-consent step for both clients. The Azure CLI is here
# so -ProbeToken works; drop it if you would rather not have it listed.
Invoke-GraphPatch "$GRAPH/applications/$apiObjId" @{
    api = @{
        preAuthorizedApplications = @(
            @{ appId = $spaAppId;      delegatedPermissionIds = @($scopeId) },
            @{ appId = $cliAppId;      delegatedPermissionIds = @($scopeId) },
            @{ appId = $AZ_CLI_APP_ID; delegatedPermissionIds = @($scopeId) }
        )
    }
}
Write-Host "Pre-authorized the App, the CLI and the Azure CLI on the API scope" -ForegroundColor Cyan

# --- assign the app role to the account running this ------------------------
$me = Invoke-Az ad signed-in-user show
$assignments = Invoke-Az rest --method GET --url "$GRAPH/users/$($me.id)/appRoleAssignments"
if (-not ($assignments.value | Where-Object { $_.appRoleId -eq $roleId -and $_.resourceId -eq $apiSp.id })) {
    $file = New-TemporaryFile
    try {
        @{ principalId = $me.id; resourceId = $apiSp.id; appRoleId = $roleId } |
            ConvertTo-Json | Set-Content -Path $file -Encoding utf8
        & az rest --method POST --url "$GRAPH/users/$($me.id)/appRoleAssignments" `
            --headers 'Content-Type=application/json' --body "@$file" -o none
        if ($LASTEXITCODE -ne 0) { throw "app role assignment failed (exit $LASTEXITCODE)" }
        Write-Host "Assigned $($me.userPrincipalName) to the 'authenticated' app role" -ForegroundColor Cyan
    } finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
} else {
    Write-Host "$($me.userPrincipalName) already holds the 'authenticated' app role" -ForegroundColor DarkGray
}

# --- close the gate: only assigned users can get a token for the API ---------
# Without this EVERY user in the tenant can obtain a token for the API; it
# merely carries no `roles` claim, and the stack maps that to `anon`. With it,
# Entra refuses the token request itself (AADSTS50105) unless the user, or a
# group they are in, holds an app role on the API — so unassigned users stop at
# Microsoft's sign-in page. It lives on the API's SERVICE PRINCIPAL (Enterprise
# applications > <prefix> API > Properties > "Assignment required?"), not on
# the registration, and the clients need nothing: the check is made against
# the resource a token is requested for. AFTER the self-assignment above, so
# the account running this is inside before the door closes. A refusal to
# issue, not the stack's only defence — PostgREST and rbac.uid() still map a
# role-less token to `anon`, so nothing here relaxes.
if (-not $apiSp.appRoleAssignmentRequired) {
    try {
        Invoke-GraphPatch "$GRAPH/servicePrincipals/$($apiSp.id)" @{ appRoleAssignmentRequired = $true }
        Write-Host "Assignment required: ON for $apiName — only assigned users get a token" -ForegroundColor Cyan
    } catch {
        # Not fatal: the stack still works, unassigned users merely reach it as
        # `anon`. Typically a re-run against a service principal somebody else
        # created — the creator owns it, and an owner may set this; others may
        # not.
        Write-Host "Could not turn on 'Assignment required' for $apiName ($_)." -ForegroundColor Yellow
        Write-Host "Set it in the Entra admin center: Enterprise applications > $apiName > Properties." -ForegroundColor Yellow
    }
} else {
    Write-Host "Assignment required already ON for $apiName" -ForegroundColor DarkGray
}

# --- the values -------------------------------------------------------------
# VITE_OAUTH_AUDIENCE and PGRST_JWT_AUD look like they should be one variable
# and are not. The first is what the SPA ASKS FOR (the RFC 8707 resource, which
# must match the scope's prefix or Entra answers AADSTS9010010); the second is
# what a v2 token actually CARRIES in `aud`, which is the bare GUID.
# CLI_OAUTH_CLIENT_ID is no longer a comment: the stack PUBLISHES it, at
# /.well-known/semantius.json, so semantius-cli can configure itself from the
# origin alone — and the Entra variant cannot start without it.
#
# ONLY what is specific to YOUR tenant. Everything else Entra needs — the
# `.roles[0]` claim key, the empty JWKS_URL, the account menu pointing at
# Microsoft's My Account — is already baked into this variant's generated
# compose, because it is the same for every Entra tenant that exists.
$values = [ordered]@{
    'VITE_OAUTH_CONFIG'        = "https://login.microsoftonline.com/$tenantId/v2.0/.well-known/openid-configuration"
    'VITE_OAUTH_CLIENT_ID'     = $spaAppId
    'VITE_OAUTH_SCOPE'         = "openid profile email offline_access api://$apiAppId/access_as_user"
    'VITE_OAUTH_AUDIENCE'      = "api://$apiAppId"
    'PGRST_JWT_AUD'            = $apiAppId
    'CLI_OAUTH_CLIENT_ID'      = $cliAppId
}

Write-Host ""
Write-Host "--- values ---------------------------------------------------" -ForegroundColor Green
foreach ($k in $values.Keys) { Write-Host "$k=$($values[$k])" }
Write-Host "--------------------------------------------------------------" -ForegroundColor Green

if (-not $NoWrite) {
    if (-not (Test-Path $EnvFile)) {
        $example = Join-Path (Split-Path $EnvFile -Parent) '.env.example'
        if (Test-Path $example) {
            Copy-Item $example $EnvFile
            Write-Host "Created $EnvFile from .env.example" -ForegroundColor DarkGray
        } else {
            New-Item -ItemType File -Path $EnvFile | Out-Null
        }
    }
    # Fill in place: replace the variable's line wherever it already is
    # (commented or not) so the file keeps its own comments and order, and
    # append only what was missing entirely.
    $lines = @(Get-Content $EnvFile)
    foreach ($k in $values.Keys) {
        $new = "$k=$($values[$k])"
        $idx = (0..($lines.Count - 1)) | Where-Object { $lines[$_] -match "^\s*#?\s*$([regex]::Escape($k))\s*=" } | Select-Object -First 1
        if ($null -ne $idx) { $lines[$idx] = $new } else { $lines += $new }
    }
    Set-Content -Path $EnvFile -Value $lines -Encoding utf8
    Write-Host "Wrote $EnvFile" -ForegroundColor Green
}

Write-Host ""
Write-Host "LEFT TO A DIRECTORY ADMIN: assign other users or groups to the app role" -ForegroundColor Yellow
Write-Host "  Entra admin center > Enterprise applications > $apiName > Users and groups" -ForegroundColor Yellow
Write-Host "A newly assigned user's FIRST token can still arrive without the roles claim —" -ForegroundColor Yellow
Write-Host "the assignment takes about a minute to reach the token service." -ForegroundColor Yellow

# --- optional probe ---------------------------------------------------------
if ($ProbeToken) {
    Write-Host ""
    Write-Host "Fetching an access token through the Azure CLI ..." -ForegroundColor Cyan
    $tok = Invoke-Az account get-access-token --scope "api://$apiAppId/access_as_user"
    $payload = $tok.accessToken.Split('.')[1]
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload.Replace('-', '+').Replace('_', '/'))) |
        ConvertFrom-Json | ConvertTo-Json -Depth 5
}

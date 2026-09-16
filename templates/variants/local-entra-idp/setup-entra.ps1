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
    groups. A user without it receives a token with no `roles` claim, which
    PostgREST maps to `anon` — the stack's way of saying "not a user here".

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
    [switch]$ProbeToken
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# --- where the browser reaches this stack -----------------------------------
# Read .env (or .env.example) beside this script for a default, then confirm.
function Get-EnvValue {
    param([string]$File, [string]$Key)
    if (-not (Test-Path $File)) { return $null }
    $line = Get-Content $File | Where-Object { $_ -match "^\s*$([regex]::Escape($Key))\s*=\s*\S" } | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -split '=', 2)[1].Trim().Trim('"').Trim("'")
}

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

# The Azure CLI's own public client id — pre-authorized on the scope so
# -ProbeToken can mint a real token without a browser.
$AZ_CLI_APP_ID = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
$GRAPH = 'https://graph.microsoft.com/v1.0'

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

# --- stop condition, before anything is created -----------------------------
# "Already configured" is the app client id having a value: that is the one
# variable the stack cannot start without, and the one this script exists to
# produce. An .env that has it is somebody's working configuration, and a
# second run must not quietly point it at new registrations.
if (-not $NoWrite -and (Test-Path $EnvFile)) {
    $existing = Get-Content $EnvFile
    $line = $existing | Where-Object { $_ -match '^\s*VITE_OAUTH_CLIENT_ID\s*=\s*\S' }
    if ($line) {
        Write-Host "$EnvFile is already configured ($($line -join '')) — nothing to do." -ForegroundColor Yellow
        Write-Host "Run with -NoWrite to print values for a different tenant, or clear that line first." -ForegroundColor Yellow
        exit 0
    }
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
$cli = Get-AppByName $cliName
if (-not $cli) {
    # The three loopback URIs semantius-cli tries, in order. They are restated
    # here because semantius-idp-config/oauth_clients.jsonc — the source of truth for them
    # — configures the BUNDLED idp and is not part of this variant at all.
    $cli = Invoke-Az ad app create --display-name $cliName --sign-in-audience AzureADMyOrg `
        --is-fallback-public-client true `
        --public-client-redirect-uris 'http://127.0.0.1:53682/callback' 'http://127.0.0.1:53683/callback' 'http://127.0.0.1:53684/callback'
    Write-Host "  created $($cli.appId)" -ForegroundColor DarkGray
} else {
    Write-Host "  exists $($cli.appId)" -ForegroundColor DarkGray
}
$cliAppId = $cli.appId
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

# --- the values -------------------------------------------------------------
# VITE_OAUTH_AUDIENCE and PGRST_JWT_AUD look like they should be one variable
# and are not. The first is what the SPA ASKS FOR (the RFC 8707 resource, which
# must match the scope's prefix or Entra answers AADSTS9010010); the second is
# what a v2 token actually CARRIES in `aud`, which is the bare GUID.
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
}

Write-Host ""
Write-Host "--- values ---------------------------------------------------" -ForegroundColor Green
foreach ($k in $values.Keys) { Write-Host "$k=$($values[$k])" }
Write-Host "# $NamePrefix CLI client id: $cliAppId   (for semantius-cli on a user's machine)"
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
    $cliNote = "# $NamePrefix CLI client id: $cliAppId"
    if (-not ($lines | Where-Object { $_ -like "*CLI client id:*" })) { $lines += $cliNote }
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

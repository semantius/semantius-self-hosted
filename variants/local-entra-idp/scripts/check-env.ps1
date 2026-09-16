# check-env.ps1  -  refuse to run docker against a stack that is not configured.
# The Windows half of the checks at the top of up.sh / create.sh; up.cmd and
# create.cmd call it before anything else.
#
# TWO things it refuses:
#   1. no .env at all — setup-env.cmd writes that file, and nothing else should.
#   2. .env present but a REQUIRED value empty. Required means `${VAR:?...}` in
#      the compose file, so the list is read from there rather than kept in step
#      by hand: a variant that needs an issuer's client id says so in its own
#      compose, and this reports it by name instead of letting compose print a
#      wall of interpolation errors.
$ErrorActionPreference = 'Stop'

$dir = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $dir '.env'
$composePath = Join-Path $dir 'docker-compose.yml'

if (-not (Test-Path -LiteralPath $envPath)) {
  Write-Host "No .env in $dir."
  Write-Host ''
  Write-Host '  setup-env.cmd    creates it from .env.example, with generated secrets'
  Write-Host ''
  Write-Host 'Then fill in anything the README marks as required, and run this again.'
  exit 1
}

$required = Select-String -Path $composePath -Pattern '\$\{([A-Z_][A-Z0-9_]*):\?' -AllMatches |
  ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

$values = @{}
foreach ($line in Get-Content -LiteralPath $envPath) {
  if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') { $values[$Matches[1]] = $Matches[2].Trim() }
}

$missing = @($required | Where-Object { -not $values[$_] })
if ($missing.Count) {
  Write-Host 'This stack needs values in .env before it can start:'
  foreach ($v in $missing) { Write-Host "  $v" }
  Write-Host ''
  Write-Host 'See README.md in this folder.'
  exit 1
}

exit 0

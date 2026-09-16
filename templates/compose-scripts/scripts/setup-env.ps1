# setup-env.ps1  -  the Windows half of setup-env.sh; ..\setup-env.cmd is the
# entry point. Keep the two in step: this generates the same secrets, with the
# same URL-safety rules, and is likewise a no-op when .env already exists. The
# `# >>> feature:<name>` markers below pair with the ones in setup-env.sh -- a
# variant build cuts both copies the same way.
#
# See setup-env.sh for the reasoning (why generation happens at .env creation and
# why the two database passwords are hex rather than base64).
$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $root '.env'
$example = Join-Path $root '.env.example'

if (Test-Path -LiteralPath $envPath) {
  Write-Host '.env already exists - leaving it untouched.'
  exit 0
}
if (-not (Test-Path -LiteralPath $example)) {
  Write-Error 'setup-env: .env.example is missing.'
  exit 1
}

function New-RandomBytes([int]$count) {
  $bytes = New-Object byte[] $count
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  return $bytes
}

# Hex for the passwords that get spliced into connection URLs -- the same split
# as setup-env.sh.
function New-UrlSafePassword { (New-RandomBytes 24 | ForEach-Object { $_.ToString('x2') }) -join '' }
# >>> feature:bundled-idp
# Base64 for IDP_SECRET, which is never spliced into a URL.
function New-Secret          { [Convert]::ToBase64String((New-RandomBytes 48)) }
# <<< feature:bundled-idp

# `[^\r\n]*` rather than `.*`: in .NET `.` matches a lone \r, so `.*$` under (?m)
# would eat the CR of a CRLF file and leave that one line LF-terminated in an
# otherwise CRLF .env. .env.example has no eol attribute, so it is checked out
# CRLF on Windows -- the substitution has to preserve whatever it finds.
function Set-EnvValue([string]$text, [string]$key, [string]$value) {
  $re = [regex]::new('(?m)^' + [regex]::Escape($key) + '=[^\r\n]*')
  if (-not $re.IsMatch($text)) {
    throw "setup-env: .env.example has no uncommented $key= line - nothing was generated for it."
  }
  # A MatchEvaluator, so `$` in a generated value can never be read as a
  # substitution pattern ($1, $&, ...) in the replacement string.
  return $re.Replace($text, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) "$key=$value" }, 1)
}

# The keys are tracked in a list, so a variant build that cuts a feature's
# entry out also drops it from the summary below -- nothing claims to have
# generated a variable that variant's .env.example does not have.
$text = [IO.File]::ReadAllText($example)
$generated = @('POSTGRES_PASSWORD', 'SEMANTIUS_AUTHENTICATOR_PASSWORD')
$text = Set-EnvValue $text 'POSTGRES_PASSWORD'                (New-UrlSafePassword)
$text = Set-EnvValue $text 'SEMANTIUS_AUTHENTICATOR_PASSWORD' (New-UrlSafePassword)
# >>> feature:bundled-idp
$text = Set-EnvValue $text 'IDP_SECRET'                       (New-Secret)
$generated = @('IDP_SECRET') + $generated
# <<< feature:bundled-idp

# Temp file then move, so an interrupted run cannot leave a half-substituted .env
# behind -- one that would boot with a dev secret still in it. UTF8 with NO BOM:
# a BOM would end up inside the first variable name compose parses.
$tmp = Join-Path $root ('.env.tmp.' + [IO.Path]::GetRandomFileName())
[IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tmp -Destination $envPath -Force

Write-Host 'Created .env from .env.example, with freshly generated secrets for'
Write-Host "  $($generated -join ', ')."
Write-Host 'They are in .env (gitignored) - that is the only copy. Read the DBA password with:'
Write-Host '  findstr /b "POSTGRES_PASSWORD=" .env'

@echo off
REM setup-env.cmd  -  create .env from .env.example on first run, with UNIQUE
REM secrets. The Windows twin of setup-env.sh; create/up call it in place of the
REM plain `copy .env.example .env` they used to do.
REM
REM Fresh IDP_SECRET, POSTGRES_PASSWORD and SEMANTIUS_AUTHENTICATOR_PASSWORD are
REM generated before the file is written, because all three are load-bearing
REM BEFORE first boot: IDP_SECRET encrypts the idp's stored signing keys, and the
REM two passwords are baked into the database by init scripts that run once per
REM data directory.
REM
REM IDEMPOTENT: an existing .env is never touched.
REM
REM Batch has no CSPRNG, so the work lives in .\scripts\setup-env.ps1 and this is
REM just the entry point -- same split as dokploy-build.cmd.
cd /d "%~dp0"

where powershell >nul 2>&1
if errorlevel 1 (
  echo powershell not found - copy .env.example to .env and set IDP_SECRET,
  echo POSTGRES_PASSWORD and SEMANTIUS_AUTHENTICATOR_PASSWORD by hand.
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup-env.ps1"
exit /b %ERRORLEVEL%

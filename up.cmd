@echo off
setlocal enabledelayedexpansion
REM up.cmd  -  (re)create the stack's CONTAINERS from the current compose config
REM and start them, KEEPING the database. See up.sh for the full rationale.
REM
REM This is "docker compose up --force-recreate". Reach for it after changing
REM docker-compose.yml, .env or the Caddyfile: the containers are replaced, your
REM data survives.
REM
REM It does NOT give you a clean database -- the image's first-init scripts run ONCE
REM per data directory, so an existing pgdata volume keeps the OLD schema no matter
REM how many times containers are recreated. For a fresh database use create.cmd.
REM
REM EVERY IMAGE COMES FROM A REGISTRY. Nothing here is built from source, so this
REM works in a fresh clone with no toolchain installed.
REM
REM Usage:
REM   up.cmd                  pull the published DB image, then up
REM   up.cmd 0.4.0-pg18       ... pinned to that tag (overrides SEMANTIUS_DB_VERSION)
REM   up.cmd --no-pull        skip the DB pull and run whatever image is already
REM                           tagged locally (for testing an image you built
REM                           yourself -- see the semantius repo's docker-postgres\)
cd /d "%~dp0"

set "PULL=1"
set "DB_VERSION="

:parse
if "%~1"=="" goto :parsed
if /i "%~1"=="--no-pull" ( set "PULL=0" & shift & goto :parse )
if /i "%~1"=="--pull" ( set "PULL=1" & shift & goto :parse )
set "ARG=%~1"
if "!ARG:~0,1!"=="-" (
  echo Unknown option: %~1
  echo Usage: up.cmd [--pull^|--no-pull] [version]
  exit /b 1
)
REM A bare argument is the image tag.
set "DB_VERSION=%~1"
shift
goto :parse
:parsed

REM A tag selects a PUBLISHED image, which only a pull can fetch -- the two cannot
REM be combined without lying about what is running.
if "%PULL%"=="0" if defined DB_VERSION (
  echo A version tag ^('!DB_VERSION!'^) applies only when pulling -- --no-pull runs whatever is tagged locally.
  exit /b 1
)

if not exist ".env" (
  copy ".env.example" ".env" >nul
  echo Created .env from .env.example - edit passwords/ports if you want.
)

REM An explicit tag wins over .env: the process environment takes precedence over
REM the .env file in docker compose's variable resolution.
if defined DB_VERSION (
  set "SEMANTIUS_DB_VERSION=!DB_VERSION!"
  echo Pinning SEMANTIUS_DB_VERSION=!DB_VERSION! for this run.
)

if "%PULL%"=="1" (
  REM The other services are pull_policy: always; `postgres` is not, because a
  REM locally built image must survive an "up" under --no-pull. So pull it here.
  REM NOTE: pulling `latest` OVERWRITES an image you built and tagged yourself.
  echo == Pulling the published DB image ==
  docker compose pull postgres || goto :err
) else (
  echo == Skipping the DB pull - running the locally tagged image ==
)

REM --force-recreate: always replace existing containers with fresh ones from the
REM current compose config, so this can never resume a stale/half-built container
REM (e.g. one left port-unpublished by an earlier failed "up"). --remove-orphans
REM drops services no longer in compose. Named volumes are kept, so this does NOT
REM lose data -- only create.cmd and destroy.cmd do.
docker compose up -d --force-recreate --remove-orphans || goto :err
docker compose ps
echo.
echo Ready (Semantius stack). Default ports (see .env):
echo   Admin: http://localhost:3000/   (SPA; API at /rest/, docs at /api-docs/)
echo   DBA : postgresql://postgres:^<POSTGRES_PASSWORD^>@localhost:5434/semantius

REM The idp warns about its own shipped defaults, but
REM SEMANTIUS_AUTHENTICATOR_PASSWORD never reaches it — only this script can
REM notice it is still the dev value.
findstr /b /c:"SEMANTIUS_AUTHENTICATOR_PASSWORD=devpassword" .env >nul 2>&1
if not errorlevel 1 (
  echo.
  echo   WARNING: SEMANTIUS_AUTHENTICATOR_PASSWORD is still the shipped default
  echo   ^('devpassword'^) - the login PostgREST uses against the database. Fine
  echo   locally; change it in .env before exposing this deployment, then up.cmd.
)
exit /b 0

:err
echo.
echo Failed. Is Docker Desktop running?
pause
exit /b 1

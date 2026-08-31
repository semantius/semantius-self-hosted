@echo off
setlocal enabledelayedexpansion
REM create.cmd  -  create the stack FROM SCRATCH: fresh containers AND a fresh
REM database. The exact inverse of destroy.cmd. See create.sh for the full
REM rationale.
REM
REM WHY IT WIPES: the image's first-init scripts (CREATE EXTENSION, the authenticator
REM LOGIN, anon, the optional NWIND load) run ONCE per data directory. Recreating
REM containers over an existing pgdata volume silently keeps the OLD schema -- so
REM "create" would hand you a stale database and a test that proves nothing.
REM
REM EVERY IMAGE COMES FROM A REGISTRY. Nothing here is built from source, so a fresh
REM clone can create the stack with no toolchain installed.
REM
REM DESTRUCTIVE: deletes this stack's volumes. Prompts when a data volume exists;
REM bypass with -y/--yes, ASSUME_YES=1 or CI=true. To KEEP your data -- after a
REM compose/.env/Caddyfile change -- use up.cmd instead.
REM
REM Usage:
REM   create.cmd                  fresh DB on the published image
REM   create.cmd 0.4.0-pg18       ... pinned to that tag
REM   create.cmd --no-pull        fresh DB on the locally tagged image (see up.cmd)
REM   create.cmd -y               skip the confirmation prompt
cd /d "%~dp0"

set "PULL=1"
set "FORCE=0"
set "DB_VERSION="

:parse
if "%~1"=="" goto :parsed
if /i "%~1"=="--no-pull" ( set "PULL=0" & shift & goto :parse )
if /i "%~1"=="--pull" ( set "PULL=1" & shift & goto :parse )
if /i "%~1"=="-y" ( set "FORCE=1" & shift & goto :parse )
if /i "%~1"=="--yes" ( set "FORCE=1" & shift & goto :parse )
set "ARG=%~1"
if "!ARG:~0,1!"=="-" (
  echo Unknown option: %~1
  echo Usage: create.cmd [--pull^|--no-pull] [version] [-y]
  exit /b 1
)
REM A bare argument is the image tag.
set "DB_VERSION=%~1"
shift
goto :parse
:parsed

if "%PULL%"=="0" if defined DB_VERSION (
  echo A version tag ^('!DB_VERSION!'^) applies only when pulling -- --no-pull runs whatever is tagged locally.
  exit /b 1
)

if not exist ".env" (
  copy ".env.example" ".env" >nul
  echo Created .env from .env.example - edit passwords/ports if you want.
)

if "%ASSUME_YES%"=="1" set "FORCE=1"
if "%CI%"=="true" set "FORCE=1"

REM Only prompt when there is actually data to lose. The compose project name is
REM parsed from `name:` in docker-compose.yml so it stays a single source of truth,
REM and the volumes are found by the label compose stamps on them.
set "PROJECT="
for /f "tokens=2 delims=: " %%A in ('findstr /b /c:"name:" docker-compose.yml') do (
  if not defined PROJECT set "PROJECT=%%A"
)
set "HASVOL="
for /f "delims=" %%V in ('docker volume ls -q --filter "label=com.docker.compose.project=%PROJECT%" 2^>nul') do set "HASVOL=1"

if defined HASVOL (
  if "%FORCE%"=="0" (
    echo An existing database volume was found for '%PROJECT%':
    docker volume ls --filter "label=com.docker.compose.project=%PROJECT%"
    set /p ans=create DELETES it ^(all data^) and starts from scratch. Continue? [y/N]
    if /i not "!ans!"=="y" (
      echo Cancelled. ^(up.cmd recreates the containers and KEEPS the data.^)
      exit /b 0
    )
  )
  echo == Wiping the stack + its volumes ^(down -v^) ==
) else (
  echo == No existing volumes - creating the stack from scratch ==
)
REM --remove-orphans as well: a bare "down" only removes containers for services
REM CURRENTLY in the compose file, so one left behind by a RENAMED service (the SPA
REM was "web" before it became "nginx") survives the wipe -- and then collides with
REM the new service over its "container_name:", failing the next up with
REM Conflict. The container name /semantius-app is already in use. up.sh passes
REM the same flag, but that one is too late: compose drops orphans AFTER creating
REM the service containers, i.e. after the conflict has already fired.
docker compose down -v --remove-orphans || goto :err

REM Everything past the wipe is exactly `up`, so it lives in one place.
set "UP_ARGS="
if "%PULL%"=="0" set "UP_ARGS=--no-pull"
if defined DB_VERSION set "UP_ARGS=!UP_ARGS! !DB_VERSION!"
call "%~dp0up.cmd" !UP_ARGS!
exit /b %ERRORLEVEL%

:err
echo.
echo Failed. Is Docker Desktop running?
pause
exit /b 1

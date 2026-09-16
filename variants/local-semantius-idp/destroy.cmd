@echo off
REM Destroy the PostgREST stack: containers, network, and data + jwks volumes.
REM Keeps the semantius/postgres image (reusable, versioned artifact) and leaves the
REM pgdocker stacks untouched.
cd /d "%~dp0"

set /p ans=This DELETES the PostgREST stack's DB volume (all data). Continue? [y/N]
if /i not "%ans%"=="y" (
  echo Cancelled.
  exit /b 0
)

REM --remove-orphans as well: a bare "down" only removes containers for services
REM CURRENTLY in the compose file, so one left behind by a RENAMED service (the SPA
REM was "web" before it became "nginx") survives the wipe -- and then collides with
REM the new service over its "container_name:", failing the next up with
REM Conflict. The container name /semantius-app is already in use. up.cmd passes
REM the same flag, but that one is too late: compose drops orphans AFTER creating
REM the service containers, i.e. after the conflict has already fired.
docker compose down -v --remove-orphans
echo Removed the PostgREST stack's containers, network, and data + jwks volumes (image kept).

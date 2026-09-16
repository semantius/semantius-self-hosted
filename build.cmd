@echo off
REM build.cmd  -  regenerate .\variants\ from .\templates\.
REM
REM TEMPLATES ARE WHAT YOU EDIT, VARIANTS ARE WHAT YOU RUN. Every folder under
REM variants\ is GENERATED and COMMITTED -- never hand-edit one. Change a file in
REM templates\, run this, commit the result.
REM
REM A variant subtracts from the one stack in templates\: "x-semantius-feature:"
REM keys mark compose nodes and "# >>> feature:<name>" pairs mark regions of the
REM text files, and templates\variants\<variant>\variant.json says which features to drop,
REM which variables the variant cannot start without, and what its defaults are.
REM
REM A generated folder keeps its own .env -- yours, with your passwords -- and a
REM rebuild never touches it.
REM
REM Usage:
REM   build.cmd                 build every variant
REM   build.cmd external-idp    build one
REM
REM The transform and its validations live in .\scripts\build.mjs; this
REM is just the entry point.
REM
REM Needs Node (uses the `yaml` package -- run `npm install` once if it is missing).
cd /d "%~dp0"

where node >nul 2>&1
if errorlevel 1 (
  echo node not found - install Node.js ^(^>=18^) to build the variants.
  exit /b 1
)

node scripts\build.mjs %*
exit /b %ERRORLEVEL%

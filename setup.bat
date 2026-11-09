@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem ====================================================================
rem  TagTrail - set up the database on this machine.
rem
rem  Double-click this file. It is a .bat rather than a .ps1 on purpose:
rem  Windows execution policy blocks .ps1 files on a managed machine, which
rem  makes the window close before you can read the error. A .bat is not
rem  subject to that, and this one pauses at every exit so you can always
rem  see what happened.
rem ====================================================================

echo.
echo  TagTrail - database setup
echo  =========================
echo.

rem --------------------------------------------------------------------
rem  1. Find psql. A default Postgres install does not put it on PATH.
rem --------------------------------------------------------------------
set "PSQL="
where psql >nul 2>&1
if %errorlevel%==0 (
  set "PSQL=psql"
) else (
  for /f "delims=" %%V in ('dir /b /o-n "C:\Program Files\PostgreSQL" 2^>nul') do (
    if not defined PSQL if exist "C:\Program Files\PostgreSQL\%%V\bin\psql.exe" (
      set "PSQL=C:\Program Files\PostgreSQL\%%V\bin\psql.exe"
    )
  )
)
if not defined PSQL (
  for /f "delims=" %%V in ('dir /b /o-n "C:\Program Files (x86)\PostgreSQL" 2^>nul') do (
    if not defined PSQL if exist "C:\Program Files (x86)\PostgreSQL\%%V\bin\psql.exe" (
      set "PSQL=C:\Program Files (x86)\PostgreSQL\%%V\bin\psql.exe"
    )
  )
)

if not defined PSQL (
  echo  Could not find psql.exe.
  echo.
  echo  It ships with PostgreSQL but is not added to PATH by default.
  echo  Look for it under:
  echo      C:\Program Files\PostgreSQL\^<version^>\bin\psql.exe
  echo.
  echo  If Postgres is installed somewhere else, open a terminal in this
  echo  folder and run the commands in the "By hand" section of README-SETUP.txt
  echo.
  pause
  exit /b 1
)
echo  Found psql: !PSQL!
echo.

rem --------------------------------------------------------------------
rem  2. Connection details
rem --------------------------------------------------------------------
set "DBHOST=localhost"
set "DBPORT=5432"
set "DBUSER=postgres"
set "DBNAME=tagtrail"

rem  set /p leaves the variable untouched when you just press Enter, so each
rem  prompt clears it first. Without this, pressing Enter at the port prompt
rem  silently reuses whatever you typed as the username.
set "ANS="
set /p "ANS=Postgres user [%DBUSER%]: "
if not "!ANS!"=="" set "DBUSER=!ANS!"
set "ANS="
set /p "ANS=Port [%DBPORT%]: "
if not "!ANS!"=="" set "DBPORT=!ANS!"

rem  The password is read without echoing it to the screen. This uses
rem  powershell -Command, which execution policy does NOT block - only .ps1
rem  files are affected, which is why this script exists.
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$s=Read-Host 'Password for %DBUSER%' -AsSecureString; [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))"`) do set "PGPASSWORD=%%P"
echo.

rem --------------------------------------------------------------------
rem  3. Prove we can connect before changing anything
rem --------------------------------------------------------------------
"!PSQL!" -h %DBHOST% -p %DBPORT% -U %DBUSER% -d postgres -c "SELECT version();" >nul 2>&1
if not %errorlevel%==0 (
  echo  Could not connect to Postgres on %DBHOST%:%DBPORT% as "%DBUSER%".
  echo.
  echo  Check that:
  echo    - the PostgreSQL service is running  ^(services.msc^)
  echo    - the port is right ^(5432 by default^)
  echo    - the password is right
  echo.
  set "PGPASSWORD="
  pause
  exit /b 1
)
echo  Connected.
echo.

rem --------------------------------------------------------------------
rem  4. Create the database
rem --------------------------------------------------------------------
for /f "delims=" %%E in ('"!PSQL!" -h %DBHOST% -p %DBPORT% -U %DBUSER% -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='%DBNAME%'"') do set "EXISTS=%%E"

if "!EXISTS!"=="1" (
  echo  A database called "%DBNAME%" already exists.
  set "DROP="
  set /p "DROP=Drop it and start clean? Everything in it is lost. (y/N): "
  if /i "!DROP!"=="y" (
    "!PSQL!" -h %DBHOST% -p %DBPORT% -U %DBUSER% -d postgres -c "DROP DATABASE %DBNAME%;" >nul
    "!PSQL!" -h %DBHOST% -p %DBPORT% -U %DBUSER% -d postgres -c "CREATE DATABASE %DBNAME%;" >nul
    echo  Recreated "%DBNAME%".
  ) else (
    echo  Keeping it. The schema will load into the existing database.
  )
) else (
  "!PSQL!" -h %DBHOST% -p %DBPORT% -U %DBUSER% -d postgres -c "CREATE DATABASE %DBNAME%;" >nul
  if not !errorlevel!==0 (
    echo  Could not create the database.
    set "PGPASSWORD="
    pause
    exit /b 1
  )
  echo  Created "%DBNAME%".
)
echo.

rem --------------------------------------------------------------------
rem  5. Load the schema. ON_ERROR_STOP so a failure stops here rather
rem     than leaving a half-built database that looks fine until it isn't.
rem --------------------------------------------------------------------
for %%F in (001_schema.sql 002_functions.sql) do (
  echo  Loading %%F ...
  "!PSQL!" -h %DBHOST% -p %DBPORT% -U %DBUSER% -d %DBNAME% -v ON_ERROR_STOP=1 -q -f "db\%%F"
  if not !errorlevel!==0 (
    echo.
    echo  %%F FAILED. Nothing further was loaded.
    set "PGPASSWORD="
    pause
    exit /b 1
  )
  echo    done
)
echo.

rem --------------------------------------------------------------------
rem  6. The guarantee tests. These are SUPPOSED to produce 12 errors -
rem     each one is the database refusing something impossible.
rem --------------------------------------------------------------------
echo  Running the guarantee tests.
echo  These print errors on purpose: each is the database refusing
echo  something that should be impossible.
echo.

set "LOG=%TEMP%\tagtrail_guarantees.txt"
"!PSQL!" -h %DBHOST% -p %DBPORT% -U %DBUSER% -d %DBNAME% -f "db\test_guarantees.sql" > "!LOG!" 2>&1

set "COUNT=0"
for /f %%C in ('findstr /c:"ERROR:" "!LOG!" ^| find /c /v ""') do set "COUNT=%%C"

echo  ------------------------------------------------------------
if "!COUNT!"=="12" (
  echo   12 refusals out of 12 expected.
  echo   The database is enforcing what it should.
) else (
  echo   !COUNT! refusals, expected 12.
  if !COUNT! LSS 12 (
    echo   Something that should be impossible is possible.
  ) else (
    echo   Something failed that was meant to succeed.
  )
  echo   Full output: !LOG!
)
echo  ------------------------------------------------------------
echo.

rem --------------------------------------------------------------------
rem  7. Point the API at it
rem --------------------------------------------------------------------
if exist "api\appsettings.json" (
  powershell -NoProfile -Command "$p='api\appsettings.json'; $j=Get-Content $p -Raw | ConvertFrom-Json; $j.ConnectionStrings.TagTrail='Host=%DBHOST%;Port=%DBPORT%;Database=%DBNAME%;Username=%DBUSER%;Password=' + $env:PGPASSWORD; $j | ConvertTo-Json -Depth 10 | Set-Content $p -Encoding UTF8"
  echo  Wrote the connection string into api\appsettings.json
  echo  That file now holds the password in plain text - do not commit it.
  echo.
)

set "PGPASSWORD="

echo  Next:
echo      cd api
echo      dotnet run
echo.
echo  Then open http://localhost:5000/api/health - it should answer {"ok":true}.
echo.
echo  The C# has never been compiled, so expect build errors on the first
echo  run. Send them over and they can be fixed.
echo.
pause

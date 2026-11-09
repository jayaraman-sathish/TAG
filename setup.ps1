<#
  TagTrail — set up the database on this machine.

  Right-click this file and choose "Run with PowerShell", or from a terminal:
      powershell -ExecutionPolicy Bypass -File setup.ps1

  It finds psql, creates the database, loads the schema, and then runs the
  guarantee tests. Those tests are MEANT to produce 12 errors — each one is the
  database refusing something it should refuse. The script counts them for you
  and tells you whether it got the right number.
#>

param(
  [string]$DbName   = "tagtrail",
  [string]$DbUser   = "postgres",
  [string]$DbHost   = "localhost",
  [int]   $DbPort   = 5432
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Say($msg, $colour = "Gray") { Write-Host $msg -ForegroundColor $colour }

# The window must never close before you have read why it stopped. Without
# this, any failure — including being blocked by execution policy on a managed
# machine — flashes up and vanishes, which looks like the script doing nothing.
function Hold($code = 0) {
  Write-Host ""
  Read-Host "Press Enter to close" | Out-Null
  exit $code
}
trap {
  Write-Host ""
  Say "Stopped: $($_.Exception.Message)" "Red"
  if ($_.InvocationInfo) { Say "  at line $($_.InvocationInfo.ScriptLineNumber)" "DarkGray" }
  Write-Host ""
  Say "If this says the file is not digitally signed or that running scripts is" "Yellow"
  Say "disabled, your machine's policy is blocking .ps1 files. Use setup.bat" "Yellow"
  Say "instead — it does the same work and is not subject to that policy." "Yellow"
  Hold 1
}

# ---------------------------------------------------------------------
# 1. Find psql. It is usually not on PATH after a default install.
# ---------------------------------------------------------------------
$psql = $null
if (Get-Command psql -ErrorAction SilentlyContinue) {
  $psql = "psql"
} else {
  $candidates = Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\psql.exe",
                              "C:\Program Files (x86)\PostgreSQL\*\bin\psql.exe" `
                              -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending
  if ($candidates) { $psql = $candidates[0].FullName }
}

if (-not $psql) {
  Say "Could not find psql.exe." "Red"
  Say ""
  Say "It ships with PostgreSQL but is not added to PATH by default. Look for it under"
  Say "  C:\Program Files\PostgreSQL\<version>\bin\psql.exe"
  Say "then run this script again from a terminal where that folder is on PATH, e.g."
  Say '  $env:Path += ";C:\Program Files\PostgreSQL\16\bin"' "Cyan"
  Hold 1
}
Say "Using $psql" "DarkGray"

# ---------------------------------------------------------------------
# 2. Password. Held only for this process, never written to disk.
# ---------------------------------------------------------------------
if (-not $env:PGPASSWORD) {
  $secure = Read-Host "Password for Postgres user '$DbUser'" -AsSecureString
  $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
      [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}

$conn = @("-h", $DbHost, "-p", $DbPort, "-U", $DbUser)

& $psql @conn -d postgres -c "SELECT version();" | Out-Null
if ($LASTEXITCODE -ne 0) {
  Say ""
  Say "Could not connect to Postgres on ${DbHost}:${DbPort} as '$DbUser'." "Red"
  Say "Check the service is running and the password is right, then try again."
  Hold 1
}
Say "Connected." "Green"

# ---------------------------------------------------------------------
# 3. Create the database
# ---------------------------------------------------------------------
$exists = & $psql @conn -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DbName';"
if ($exists -eq "1") {
  Say ""
  Say "A database called '$DbName' already exists." "Yellow"
  $answer = Read-Host "Drop it and start clean? Everything in it will be lost. (y/N)"
  if ($answer -eq "y") {
    & $psql @conn -d postgres -c "DROP DATABASE $DbName;" | Out-Null
    & $psql @conn -d postgres -c "CREATE DATABASE $DbName;" | Out-Null
    Say "Recreated '$DbName'." "Green"
  } else {
    Say "Keeping it. The schema will be loaded into the existing database." "DarkGray"
  }
} else {
  & $psql @conn -d postgres -c "CREATE DATABASE $DbName;" | Out-Null
  Say "Created '$DbName'." "Green"
}

# ---------------------------------------------------------------------
# 4. Load the schema. ON_ERROR_STOP so a failure stops here rather than
#    leaving a half-built database that looks fine until it doesn't.
# ---------------------------------------------------------------------
foreach ($file in @("001_schema.sql", "002_functions.sql")) {
  $path = Join-Path $here "db\$file"
  Say ""
  Say "Loading $file ..."
  & $psql @conn -d $DbName -v ON_ERROR_STOP=1 -q -f $path
  if ($LASTEXITCODE -ne 0) { Say "$file failed. Nothing further was loaded." "Red"; Hold 1 }
  Say "  done" "Green"
}

# ---------------------------------------------------------------------
# 5. The guarantee tests. These are supposed to fail — 12 times.
# ---------------------------------------------------------------------
Say ""
Say "Running the guarantee tests. These produce errors on purpose:" "Cyan"
Say "each one is the database refusing something that should be impossible." "DarkGray"
Say ""

$log = Join-Path $env:TEMP "tagtrail_guarantees.txt"
& $psql @conn -d $DbName -f (Join-Path $here "db\test_guarantees.sql") *>&1 |
    Tee-Object -FilePath $log | Out-Null

$errors = (Select-String -Path $log -Pattern "ERROR:" -AllMatches).Count

if ($errors -eq 12) {
  Say "12 refusals out of 12 expected. The database is enforcing what it should." "Green"
} elseif ($errors -lt 12) {
  Say "Only $errors refusals, expected 12." "Red"
  Say "Something that should be impossible is possible. Full output: $log" "Red"
} else {
  Say "$errors refusals, expected 12 — something failed that was meant to succeed." "Yellow"
  Say "Full output: $log" "Yellow"
}

# ---------------------------------------------------------------------
# 6. Point the API at it
# ---------------------------------------------------------------------
$settings = Join-Path $here "api\appsettings.json"
if (Test-Path $settings) {
  $json = Get-Content $settings -Raw | ConvertFrom-Json
  $json.ConnectionStrings.TagTrail =
      "Host=$DbHost;Port=$DbPort;Database=$DbName;Username=$DbUser;Password=$env:PGPASSWORD"
  $json | ConvertTo-Json -Depth 10 | Set-Content $settings -Encoding UTF8
  Say ""
  Say "Wrote the connection string into api\appsettings.json." "Green"
  Say "It now contains the password in plain text, so do not commit that file." "Yellow"
}

Say ""
Say "Next:" "Cyan"
Say "  cd api"
Say "  dotnet run"
Say ""
Say "Then open http://localhost:5000/api/health — it should answer {ok:true}."
Say "The C# has never been compiled, so expect to fix build errors on the first run."
Say ""

$env:PGPASSWORD = $null
Hold 0

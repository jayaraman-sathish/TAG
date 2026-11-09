TagTrail — getting it running on this machine
=============================================

Double-click  setup.bat


Why not setup.ps1
-----------------
Right-clicking a .ps1 and choosing "Run with PowerShell" uses whatever
execution policy the machine has. On a managed or corporate machine that is
usually Restricted or AllSigned, so the script is refused, the error prints,
and the window closes before anyone can read it. The result looks like the
script doing nothing at all.

setup.bat does the same work and is not subject to execution policy. It also
pauses at every exit, so you can always see what happened.

(setup.ps1 still works if you want it — run it from a PowerShell window that
is already open, so it cannot vanish:
    powershell -ExecutionPolicy Bypass -File setup.ps1 )


What setup.bat does
-------------------
 1. Finds psql.exe, which a default Postgres install does not put on PATH.
 2. Asks for your Postgres user, port and password. The password is typed
    hidden and is never written to a file by this step.
 3. Checks it can connect before it changes anything.
 4. Creates the "tagtrail" database (offering to drop an existing one).
 5. Loads db\001_schema.sql and db\002_functions.sql.
 6. Runs db\test_guarantees.sql.
 7. Writes the connection string into api\appsettings.json.


The bit that looks like a failure but is not
--------------------------------------------
Step 6 prints a screen of red ERROR: lines. That is correct and expected.

Each one is the database refusing something that should be impossible:
editing the audit trail, two assets holding one tag, deleting an area out of a
running audit, an audit signed off by the person who opened it, two handhelds
claiming the same area, a duplicate job for the same asset.

The script counts them and tells you:

    12 refusals out of 12 expected.
    The database is enforcing what it should.

If it reports FEWER than 12, something that should be impossible is possible,
and that is worth reporting back. If it reports MORE than 12, something that
was meant to succeed failed. Either way the full output is saved to
%TEMP%\tagtrail_guarantees.txt


By hand, if you prefer
----------------------
psql is not on PATH after a default install, so put it there first. Adjust the
version number to match what you have installed:

    set PATH=%PATH%;C:\Program Files\PostgreSQL\16\bin

    psql -U postgres -c "CREATE DATABASE tagtrail;"
    psql -U postgres -d tagtrail -v ON_ERROR_STOP=1 -f db\001_schema.sql
    psql -U postgres -d tagtrail -v ON_ERROR_STOP=1 -f db\002_functions.sql
    psql -U postgres -d tagtrail -f db\test_guarantees.sql

Then edit api\appsettings.json and put your password in the connection string.


Then the API
------------
    cd api
    dotnet run

Open http://localhost:5000/api/health — it should answer {"ok":true}, which
means .NET is talking to Postgres.

The C# has never been compiled. There was no .NET SDK available where it was
written, so the first "dotnet run" will probably throw build errors — most
likely around the dynamic rows in Program.cs. Send the errors over and they
can be fixed. That is expected, and is not a sign that anything is wrong with
the design.

api\appsettings.json will hold your database password in plain text once
setup.bat has run. Do not commit that file.

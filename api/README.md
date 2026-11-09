# TagTrail — API

ASP.NET Core 8 minimal API over the Postgres schema in `../db`.

## Read this first: what has and has not been checked

I could not compile this. The container it was written in has no .NET SDK and
the Microsoft package feed is blocked by its proxy, so `dotnet build` has never
run against it. Expect to fix compile errors — most likely around Dapper's
`dynamic` rows in `Program.cs`, which the compiler is stricter about than I can
be from here.

What **has** been checked, against a real PostgreSQL 16 instance:

- **All 34 statements in `Sql.cs` parse against the actual schema.** Each one
  was prepared on the live database, which resolves every table, column, type
  and function name. A typo in a column would have failed.
- **Five statements whose semantics could fail silently were executed with real
  data**, because parsing proves nothing about whether a CTE does what its
  author thought:

  | Checked | Result |
  |---|---|
  | `UpsertReads` — a repeat read of the same tag | best signal held at −55, median moved to −70, count 2 |
  | `RecordHandover` — the CTE actually moves the sweep | sweep passed to Deepa, handover row written naming Arun and 2 reads |
  | `RaiseTask` — a second identical job | same job id, `was_new` false, priority 2 → 3, still exactly one job |
  | `ApplyRetag` with a **wrong** PIN | 0 rows, tag unmoved, `retag_count` 0, no record written |
  | `ApplyRetag` with the right PIN | tag moved and record written together |

  The fourth is the one that mattered most. A half-done replacement — tag moved
  with no signed record beside it — is exactly what the whole mechanism exists
  to prevent, and the CTE makes it impossible rather than unlikely.

## Running it

```bat
cd api
dotnet restore
dotnet run
```

Point `ConnectionStrings:TagTrail` in `appsettings.json` at your database.
Swagger is at `/swagger` in development; `/api/health` returns `{ok:true}` when
the database answers.

## Why raw SQL and not EF Core

The schema is hand-written and authoritative. It carries partial unique
indexes, check constraints, append-only triggers and a `rev` discipline — and
an EF migration diffing against it would want to "correct" the very things that
make it safe. Dapper over Npgsql keeps the SQL readable, reviewable, and
liftable into psql, which is how it was verified.

## The shape of it

| Area | Endpoints |
|---|---|
| Identity | `POST /api/auth/signin`, `POST /api/auth/signout` |
| Register | `GET /api/assets`, `PUT /api/assets/{id}`, `POST /api/assets/{id}/status` |
| Audits | `POST /api/rounds`, `POST /api/rounds/{id}/close`, `POST /api/rounds/{id}/signoff` |
| Sweeps | `GET /api/sweeps/live`, `POST /api/sweeps`, `POST /api/sweeps/{id}/reads`, `POST /api/sweeps/{id}/resume`, `POST /api/sweeps/{id}/commit` |
| Tags | `POST /api/retags` |
| Reports | `GET /api/reports/round/{id}`, `GET /api/reports/far`, `GET /api/reports/overdue-returns`, `GET /api/changelog` |

## Decisions worth knowing about

**A database refusal is an answer, not a fault.** `Db.Describe` turns each
Postgres error code into the right HTTP status and a sentence written for
whoever is holding the reader. A stale write becomes `409` with "somebody else
changed this while you had it open — nothing was saved, so nothing of theirs
was lost either." Letting those surface as `500` would make a correct guard look
like a broken server, and the operator would learn to press the button again.

**Permissions are checked here as well as in the console.** The console is a
web page on a device anyone can open. It hid buttons; hiding a button is not a
permission.

**Reads arrive in batches.** A handheld streams tens of tags a second.
`POST /sweeps/{id}/reads` takes parallel arrays and lands a batch of five
hundred in one statement, instead of five hundred round trips.

**A live sweep belongs to the server.** `GET /sweeps/live` is what lets a second
handheld pick up an area when a battery dies — and `POST /sweeps` refuses a
second sweep of an area somebody is already scanning, naming who holds it and
how many tags they have read. Two sweeps of one area means one of them is
thrown away.

**Commit splits "not read" three ways.** Away from the plant, moves by design,
or genuinely not found. Only the last is a discrepancy. An asset confirmed by
eye because its tag could not be read counts as verified and raises a re-tag
job, not a search party, and leaves the value-at-risk figure — which is the
number CARO 3(i)(b) asks about.

**Sign-in records failures.** Including the attempt by somebody with no PIN,
which the previous build allowed through with no credential at all. Exporting
the register is recorded too: it is the read-only auditor's one risky action.

## Not done yet

- **No tests.** There is no xUnit project. Given the five semantics above were
  verified in SQL, the highest-value tests to write next are HTTP-level ones
  against a throwaway database — particularly the 409 paths, which are the ones
  a client will get wrong.
- **Cookie sessions, not SSO.** Fine for the POC; the identity is resolved in
  one place (`CurrentAsync`) precisely so it can be replaced with the plant's
  own sign-on without touching the endpoints.
- **No rate limiting and no HTTPS redirect.** Both belong in front of this,
  not in it.
- **Cross-read detection is reported, not acted on.** `GET /reports/round/{id}`
  returns the candidates beside the findings so a reviewer can see which
  exceptions are RF physics. Having the commit mark them automatically needs
  the adjacency table populated with the real plant layout first, which is a
  conversation with whoever knows the walls.

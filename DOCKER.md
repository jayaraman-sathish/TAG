# Running the whole thing in Docker

One command, nothing to install but Docker Desktop:

```
cd C:\tag
docker compose up --build
```

Then open <http://localhost:5000>.

Sign in as **Arun Prakash**, PIN **1234**.

## What it does on the first run

1. Starts PostgreSQL 16 in a container.
2. Loads `db\001_schema.sql`, `db\002_functions.sql` and `db\003_seed.sql`
   automatically, in that order.
3. Waits until the database actually answers before starting the API — not
   just until the container exists, which is the usual cause of a service
   dying on its first query.
4. Builds the API with the .NET 8 SDK *inside the container*, so the .NET 10
   SDK on your machine is not involved and cannot disagree with it.
5. Serves the console at <http://localhost:5000>.

## Why this is easier than what we were doing

Every problem from this morning disappears, because none of these are
involved any more:

- psql not on PATH
- the hidden password prompt that would not accept a paste
- PowerShell execution policy blocking a `.ps1`
- a `.bat` quoting bug
- your .NET 10 SDK against a project targeting .NET 8
- remembering to run the three SQL files in the right order

## Day to day

```
docker compose up -d          # start in the background
docker compose logs -f api    # watch the API, including build errors
docker compose logs -f db     # watch the database
docker compose down           # stop, keeping the data
docker compose down -v        # stop and WIPE the data
docker compose up --build     # rebuild after a code change
```

The schema and seed run **only when the data volume is empty**. After a code
change, `--build` is enough. To start the database from scratch, use
`down -v` first — that is also how you re-run the seed.

## Getting at the database directly

The container's Postgres is published on **5433**, not 5432, so it does not
collide with the one already installed on this machine:

```
psql -h localhost -p 5433 -U tagtrail -d tagtrail      # password: tagtrail
```

Or from inside the container, where no password is needed:

```
docker compose exec db psql -U tagtrail -d tagtrail
```

That is also the easiest way to run the guarantee tests:

```
docker compose exec -T db psql -U tagtrail -d tagtrail < db\test_guarantees.sql
```

It should print **12** errors. Each one is the database refusing something
that should be impossible. Twelve is the pass mark.

## Before this goes anywhere real

The password here is `tagtrail`, in plain text, in a file. That is fine for a
POC on your laptop and unacceptable on a plant network. It belongs in Docker
secrets or the environment, and the database should not be published on a
host port at all once the API is the only thing that talks to it.

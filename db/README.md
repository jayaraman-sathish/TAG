# TagTrail — database

Postgres schema for the RFID fixed-asset audit. Tested on PostgreSQL 16.

## Running it on your machine

```bat
createdb -U postgres tagtrail
psql -U postgres -d tagtrail -v ON_ERROR_STOP=1 -f 001_schema.sql
psql -U postgres -d tagtrail -v ON_ERROR_STOP=1 -f 002_functions.sql
psql -U postgres -d tagtrail -f test_guarantees.sql
```

Everything lives in a `tagtrail` schema, so it will not collide with anything
already in the database. Three extensions are needed and are created by the
script: `pgcrypto`, `citext` and `pg_trgm` — all ship with a standard Postgres
install, no separate download.

`test_guarantees.sql` is meant to produce errors. Twelve of them, each one
immediately below the thing it was trying to do wrong. If you see twelve, the
database is enforcing what it should. If you see eleven, something that should
be impossible is possible.

## Why the database does this work rather than the application

The browser build could ask nicely. It could not guarantee. Four handhelds
scanning at once, an auditor asking who changed a cost two years ago, and a
tag mapping that decides where every asset "is" — none of that survives being
enforced in JavaScript on a device somebody can refresh.

| Guarantee | How | Was, in the browser build |
|---|---|---|
| The change log cannot be altered | `deny_change()` trigger on UPDATE and DELETE | Aged out at 2,000 entries; the app could rewrite it |
| A tag replacement cannot be altered | same trigger on `retag` | Same |
| A stale write is refused | `rev` column + `bump_rev()` trigger, raises `40001` | Last device to save won, silently |
| Two assets cannot share a tag | partial unique index on live assets | Checked in JavaScript against one device's copy |
| Audit references cannot collide | `next_round_ref()` over `ref_counter` | Counted rows and added one; two supervisors got the same ref |
| An area cannot vanish from a running audit | `round_scope` + `ON DELETE RESTRICT` | Deleting it let the audit close at 100% with the area never counted |
| An audit cannot be self-signed | `signer_is_not_the_opener` check | Enforced in the UI only |
| One live sweep per area | partial unique index | Four devices each thought they owned the area |
| One open job per asset per type | partial unique index | Deduplicated per device, so four devices raised four jobs |
| PINs are never stored or compared in the clear | `set_pin()` / `verify_pin()`, bcrypt | Plaintext in localStorage, compared in the browser |

## Decisions worth knowing about

**Depreciation is a function, not a column.** `net_block(asset, as_on)` computes
from cost, date put to use, life and method every time it is asked. A stored
net block goes stale the moment someone corrects a useful life, and nothing
tells you which rows are now wrong. The cost of recomputing is far smaller than
the cost of a register that quietly disagrees with itself.

**`as_on` is a parameter, not a setting.** Every figure can be asked for as at a
date, so the year-end register and the physical-verification report cannot
quote two different rupee figures for the same discrepancy. The browser build
froze values at commit using whatever the global as-on happened to be.

**Six asset statuses, not three.** `at_repair`, `on_loan` and `in_transit` are
on the books and still depreciating, but legitimately not in the plant. With
only active/scrapped/written-off, a motor at the rewinding vendor is reported
missing every sweep and lands in the net-block figure CARO 3(i)(b) asks about —
which is the number the auditor challenges first. `due_back` is required
thinking: without it, "out for repair" becomes a parking space.

**Every tag read is kept.** `sweep_read` holds the EPC, the best RSSI *and* the
median, with the read count. The browser build kept only counts, so a disputed
finding could never be re-examined. Keeping the median matters because the
floor was being applied to the maximum, and over forty minutes one lucky
reflection off a neighbour's tag promotes it permanently.

**`location_adjacency` is there for the cross-read problem.** UHF at 24 dBm
reads through plasterboard, so adjacent areas cross-read constantly. The table
and the `cross_read_candidates` view let a commit recognise "belongs next door,
read faintly, confirmed next door the same day" as physics rather than raising a
Return job against a team for an asset that never moved. The detection logic
sits in the API, not here.

**Photographs are references.** `photo.storage_key` points at a file or an
object; the bytes do not go in the row. Data URLs in rows are how the browser
build filled its 5 MB budget with twenty-two photographs.

## What this does not do yet

- No row-level security. For the POC the API is the only client and it
  connects as one role. Before a plant rollout, the read-only auditor role
  should be a database role too, not only an application one.
- No partitioning on `change_log`, `access_log` or `sweep_read`. These are the
  three that grow without bound. At one plant's volume it will be years before
  it matters, but they are the right candidates when it does.
- Backup and retention are not configured here. A statutory audit trail that
  is not backed up is not an audit trail.

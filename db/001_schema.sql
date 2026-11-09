-- =====================================================================
-- TagTrail — RFID fixed-asset audit
-- Postgres schema (tested on PostgreSQL 16)
--
-- Written for Panasonic Life Solutions India: multi-plant, statutory
-- physical verification under Schedule II of the Companies Act 2013 and
-- CARO 3(i)(b).
--
-- The guiding rule here is that the database enforces what the browser was
-- only asking nicely for. Four handhelds working at once, an auditor who
-- will ask who changed a cost two years ago, and a tag mapping that decides
-- where every asset "is" — none of those can be protected by client-side
-- JavaScript. So:
--
--   * the change log and tag replacements are append-only, enforced by
--     triggers, not by convention;
--   * every mutable row carries a rev, and a stale write is rejected rather
--     than silently overwriting a colleague's work;
--   * PINs are stored as bcrypt hashes and verified in the database;
--   * audit references come from a sequence, so two supervisors opening an
--     audit in the same month cannot both get AUD-2026-10-003;
--   * the scope of an audit is a table with a restricting foreign key, so an
--     area cannot be deleted out from under a running audit.
--
-- Run order: 001_schema.sql, then 002_functions.sql, then 003_seed.sql.
-- =====================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), crypt()
CREATE EXTENSION IF NOT EXISTS citext;     -- case-insensitive codes
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- substring search on code and name

CREATE SCHEMA IF NOT EXISTS tagtrail;
SET search_path TO tagtrail, public;

-- ---------------------------------------------------------------------
-- Enumerations
-- ---------------------------------------------------------------------

-- Three statuses were not enough for a factory. A megger goes to the
-- calibration lab for three weeks; a motor goes to the rewinding vendor for
-- a month. Those assets are on the books, still depreciating, and
-- legitimately not in the plant. Reported as missing they raise a job nobody
-- can close and they land in the net-block figure CARO asks about.
CREATE TYPE asset_status AS ENUM (
  'active',
  'at_repair',      -- at a vendor or the calibration lab
  'on_loan',        -- lent to another plant or site
  'in_transit',     -- moving between plants
  'scrapped',
  'written_off'
);

CREATE TYPE dep_method AS ENUM ('SLM','WDV');

CREATE TYPE user_role AS ENUM (
  'viewer',         -- statutory auditor, plant head: reads, never writes
  'operator',
  'supervisor',
  'approver',       -- finance: signs off write-offs
  'admin'
);

CREATE TYPE round_status AS ENUM ('open','closed','abandoned');

-- What a sweep concluded about one tag or one asset.
CREATE TYPE finding AS ENUM (
  'inplace',
  'misplaced',
  'missing',
  'unknown',        -- a tag no asset holds
  'away',           -- flagged as moving between areas by design
  'offsite',        -- away from the plant, with a status to say so
  'retired',        -- a replaced tag, still physically in the area
  'eyeballed'       -- seen by eye; the tag could not be read
);

CREATE TYPE task_type AS ENUM ('locate','return','identify','retag','retire');
CREATE TYPE task_status AS ENUM ('open','progress','done','approval','closed');

CREATE TYPE retag_reason AS ENUM (
  'damaged','lost','wrong','service','destroyed','relabel'
);

-- ---------------------------------------------------------------------
-- Optimistic concurrency
--
-- Four handhelds hold their own copy of a record. Without this, the last one
-- to press save wins and silently discards whatever the others did — a cost
-- correction overwritten by a sweep's last-seen update, with no trace.
-- Every mutable table carries rev; the trigger bumps it and refuses a write
-- that was based on a stale read.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION bump_rev() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- A caller that supplies the rev it read is checked against the row as
    -- it stands. A caller that supplies 0 is explicitly saying "I do not
    -- care" — reserved for migrations and admin repair, never the app.
    IF NEW.rev IS DISTINCT FROM OLD.rev AND NEW.rev <> 0 THEN
      RAISE EXCEPTION
        'stale write to %.% id=%: you read rev %, the row is now rev %',
        TG_TABLE_SCHEMA, TG_TABLE_NAME, OLD.id, NEW.rev, OLD.rev
        USING ERRCODE = '40001';   -- serialization_failure; clients retry
    END IF;
    NEW.rev := OLD.rev + 1;
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END $$;

-- Append-only. Used on the change log and on tag replacements: evidence that
-- the application can rewrite is not evidence.
CREATE OR REPLACE FUNCTION deny_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION
    '%.% is append-only; % is not permitted',
    TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP
    USING ERRCODE = '42501';       -- insufficient_privilege
END $$;

-- ---------------------------------------------------------------------
-- Site, departments, people
-- ---------------------------------------------------------------------

CREATE TABLE site (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        citext NOT NULL UNIQUE,
  name        text   NOT NULL,
  -- Reader and policy settings travel with the site, not the device, so a
  -- replacement handheld inherits them.
  rssi_floor  smallint NOT NULL DEFAULT -70
              CHECK (rssi_floor BETWEEN -95 AND -20),
  tx_power    smallint NOT NULL DEFAULT 24
              CHECK (tx_power BETWEEN 5 AND 30),   -- dBm, not centi-dBm
  dwell_ms    integer  NOT NULL DEFAULT 400 CHECK (dwell_ms > 0),
  sla_locate  smallint NOT NULL DEFAULT 7,
  sla_return  smallint NOT NULL DEFAULT 3,
  sla_identify smallint NOT NULL DEFAULT 5,
  wo_limit    numeric(14,2) NOT NULL DEFAULT 25000,
  as_on       date,            -- year-end register date; null means today
  rev         integer NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE team (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id    uuid NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
  code       citext NOT NULL,
  name       text NOT NULL,
  lead_name  text,
  email      text,
  rev        integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, code)
);

CREATE TABLE person (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id     uuid NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
  emp_code    citext NOT NULL,
  name        text NOT NULL,
  role        user_role NOT NULL DEFAULT 'operator',
  team_id     uuid REFERENCES team(id) ON DELETE SET NULL,
  -- bcrypt, never the PIN itself. set_pin() writes it; verify_pin() checks
  -- it. The browser never sees this column and never does the comparison.
  pin_hash    text,
  active      boolean NOT NULL DEFAULT true,
  -- A tag replacement must be signed. A person with no PIN cannot sign, and
  -- an unsigned replacement is worse than none, so the API refuses it.
  rev         integer NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, emp_code)
);

CREATE INDEX person_active_idx ON person (site_id) WHERE active;

-- ---------------------------------------------------------------------
-- Areas
-- ---------------------------------------------------------------------

CREATE TABLE location (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id    uuid NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
  code       citext NOT NULL,
  name       text NOT NULL,
  -- The building or zone the area sits in ("Plant A", "Warehouse C"). Not a
  -- second location table: it groups areas on screen and in the export, and
  -- is what a stores clerk reads to tell two Tool Cribs apart.
  area       text,
  team_id    uuid REFERENCES team(id) ON DELETE SET NULL,
  owner_name text,
  email      text,
  -- The tag fixed at the door, so a sweep starts by scanning the area itself
  -- rather than picking from a list.
  anchor_epc citext UNIQUE,
  rev        integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, code)
);

-- UHF at 24 dBm reads through plasterboard and open doorways, so adjacent
-- areas cross-read each other constantly. Recording which areas touch lets a
-- sweep treat "belongs next door, read faintly, confirmed next door the same
-- day" as a cross-read rather than raising a Return job against a team for
-- an asset that never moved.
CREATE TABLE location_adjacency (
  location_id  uuid NOT NULL REFERENCES location(id) ON DELETE CASCADE,
  neighbour_id uuid NOT NULL REFERENCES location(id) ON DELETE CASCADE,
  -- How porous the boundary is: an open doorway bleeds more than a brick wall.
  porosity     smallint NOT NULL DEFAULT 2 CHECK (porosity BETWEEN 1 AND 3),
  PRIMARY KEY (location_id, neighbour_id),
  CHECK (location_id <> neighbour_id)
);

-- ---------------------------------------------------------------------
-- Asset classes and assets
-- ---------------------------------------------------------------------

CREATE TABLE asset_class (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id       uuid NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
  code          citext NOT NULL,
  name          text NOT NULL,
  useful_life   smallint CHECK (useful_life BETWEEN 1 AND 60),
  method        dep_method NOT NULL DEFAULT 'SLM',
  residual_pct  numeric(5,2) NOT NULL DEFAULT 5.00
                CHECK (residual_pct >= 0 AND residual_pct <= 25),
  it_rate_pct   numeric(5,2) CHECK (it_rate_pct >= 0 AND it_rate_pct <= 100),
  dept_team_id  uuid REFERENCES team(id) ON DELETE SET NULL,
  rev           integer NOT NULL DEFAULT 1,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, code)
);

CREATE TABLE asset (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id       uuid NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
  code          citext NOT NULL,
  name          text NOT NULL,
  category      text,
  home_id       uuid REFERENCES location(id) ON DELETE RESTRICT,
  class_id      uuid REFERENCES asset_class(id) ON DELETE RESTRICT,

  epc           citext,
  tagged_at     timestamptz,
  tagged_by     uuid REFERENCES person(id) ON DELETE SET NULL,
  tagged_team   uuid REFERENCES team(id) ON DELETE SET NULL,
  verified_at   timestamptz,
  verified_by   uuid REFERENCES person(id) ON DELETE SET NULL,
  retag_count   integer NOT NULL DEFAULT 0,

  cost          numeric(14,2) CHECK (cost >= 0),
  in_use_date   date,
  -- Per-asset overrides. Null means the class decides, which is what it
  -- should normally do.
  life_override     smallint CHECK (life_override BETWEEN 1 AND 60),
  method_override   dep_method,
  residual_override numeric(5,2) CHECK (residual_override >= 0 AND residual_override <= 25),

  status        asset_status NOT NULL DEFAULT 'active',
  status_note   text,
  status_at     timestamptz,
  -- Only meaningful while the status is at_repair, on_loan or in_transit.
  -- Without it, "out for repair" quietly becomes a parking space for
  -- anything inconvenient.
  due_back      date,

  -- Laptops, clamp meters, trolleys. Never reported missing when they are
  -- not in their home area, never a job when they turn up elsewhere, and
  -- excluded from the expected count so coverage stays an honest number.
  mobile        boolean NOT NULL DEFAULT false,

  custodian_id  uuid REFERENCES person(id) ON DELETE SET NULL,
  last_seen_id  uuid REFERENCES location(id) ON DELETE SET NULL,
  last_seen_at  timestamptz,

  rev           integer NOT NULL DEFAULT 1,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  UNIQUE (site_id, code),

  CONSTRAINT due_back_only_when_away CHECK (
    due_back IS NULL OR status IN ('at_repair','on_loan','in_transit')
  ),
  CONSTRAINT depreciation_needs_a_date CHECK (
    cost IS NULL OR in_use_date IS NOT NULL
  )
);

-- One tag, one asset. A duplicate EPC means two assets claim the same
-- identity and every later audit is wrong, so the database refuses it —
-- scoped to assets still on the books, since a scrapped asset's tag may
-- legitimately be reissued.
CREATE UNIQUE INDEX asset_epc_live_uniq
  ON asset (site_id, epc)
  WHERE epc IS NOT NULL AND status NOT IN ('scrapped','written_off');

CREATE INDEX asset_home_idx   ON asset (home_id) WHERE status NOT IN ('scrapped','written_off');
CREATE INDEX asset_class_idx  ON asset (class_id);
CREATE INDEX asset_status_idx ON asset (site_id, status);
CREATE INDEX asset_due_back_idx ON asset (due_back)
  WHERE status IN ('at_repair','on_loan','in_transit');
-- The register is searched by code and name constantly; at 20,000 assets a
-- sequential scan per keystroke is what made the browser build unusable.
CREATE INDEX asset_code_trgm ON asset USING gin (code gin_trgm_ops);
CREATE INDEX asset_name_trgm ON asset USING gin (name gin_trgm_ops);

-- ---------------------------------------------------------------------
-- Audits: the exercise, and the sweeps inside it
-- ---------------------------------------------------------------------

CREATE TABLE audit_round (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id       uuid NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
  -- Generated by next_round_ref(), never by counting existing rows.
  ref           text NOT NULL,
  title         text NOT NULL,
  reason        text NOT NULL,
  status        round_status NOT NULL DEFAULT 'open',

  opened_by     uuid NOT NULL REFERENCES person(id) ON DELETE RESTRICT,
  opened_at     timestamptz NOT NULL DEFAULT now(),
  closed_by     uuid REFERENCES person(id) ON DELETE RESTRICT,
  closed_at     timestamptz,
  -- A closed audit still needs a second pair of eyes before it reaches
  -- finance, and not the person who opened it.
  signed_off_by uuid REFERENCES person(id) ON DELETE RESTRICT,
  signed_off_at timestamptz,

  rev           integer NOT NULL DEFAULT 1,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  UNIQUE (site_id, ref),
  CONSTRAINT signer_is_not_the_opener CHECK (
    signed_off_by IS NULL OR signed_off_by <> opened_by
  ),
  CONSTRAINT closed_has_a_closer CHECK (
    (status <> 'closed') OR (closed_by IS NOT NULL AND closed_at IS NOT NULL)
  )
);

-- Scope as rows, not a JSON array. In the browser build, deleting an area
-- made it vanish from the scope: the audit then closed as complete with that
-- area never counted and never listed as skipped. A restricting foreign key
-- makes that impossible rather than merely discouraged.
CREATE TABLE round_scope (
  round_id    uuid NOT NULL REFERENCES audit_round(id) ON DELETE CASCADE,
  location_id uuid NOT NULL REFERENCES location(id) ON DELETE RESTRICT,
  PRIMARY KEY (round_id, location_id)
);

CREATE TABLE round_skip (
  round_id    uuid NOT NULL REFERENCES audit_round(id) ON DELETE CASCADE,
  location_id uuid NOT NULL REFERENCES location(id) ON DELETE RESTRICT,
  reason      text NOT NULL CHECK (length(btrim(reason)) > 0),
  skipped_by  uuid NOT NULL REFERENCES person(id) ON DELETE RESTRICT,
  skipped_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (round_id, location_id)
);

-- One area, scanned once, by one person — or by two, if a shift ended in the
-- middle of it.
CREATE TABLE sweep (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id      uuid NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
  round_id     uuid REFERENCES audit_round(id) ON DELETE RESTRICT,
  location_id  uuid NOT NULL REFERENCES location(id) ON DELETE RESTRICT,

  operator_id  uuid NOT NULL REFERENCES person(id) ON DELETE RESTRICT,
  started_at   timestamptz NOT NULL,
  ended_at     timestamptz,            -- null while the sweep is still live
  committed    boolean NOT NULL DEFAULT false,

  rssi_floor   smallint NOT NULL,      -- as used, not as configured now
  tx_power     smallint,
  expected_n   integer,                -- tagged, on-site, not mobile
  register_n   integer,                -- every asset homed here, full stop

  -- Frozen at commit, with the date they were computed as at, so two
  -- statutory reports cannot quote two different rupee figures for the same
  -- discrepancy.
  value_checked numeric(16,2),
  value_missing numeric(16,2),
  valued_as_on  date,

  area_photo_id uuid,

  rev          integer NOT NULL DEFAULT 1,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT committed_has_ended CHECK (
    (NOT committed) OR (ended_at IS NOT NULL)
  )
);

-- A live sweep belongs to the server, not to one browser's localStorage.
-- That is what lets a second handheld pick up an area when a battery dies,
-- and what stops four devices each believing they own the same area.
CREATE UNIQUE INDEX sweep_one_live_per_area
  ON sweep (round_id, location_id)
  WHERE NOT committed;

CREATE INDEX sweep_round_idx ON sweep (round_id);
CREATE INDEX sweep_area_time_idx ON sweep (location_id, ended_at DESC);

-- Every tag read, kept. The browser build threw these away on commit and
-- stored only the counts, so a disputed finding could never be re-examined.
CREATE TABLE sweep_read (
  sweep_id   uuid NOT NULL REFERENCES sweep(id) ON DELETE CASCADE,
  epc        citext NOT NULL,
  -- Both, because the floor was being applied to the maximum, and over forty
  -- minutes one lucky reflection off a neighbour's tag promotes it
  -- permanently. The best and the typical reading tell different stories.
  rssi_max   smallint NOT NULL,
  rssi_med   smallint,
  read_count integer NOT NULL DEFAULT 1,
  first_at   timestamptz NOT NULL DEFAULT now(),
  last_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (sweep_id, epc)
);

-- What the sweep concluded, per asset or per stray tag.
CREATE TABLE sweep_row (
  id          bigserial PRIMARY KEY,
  sweep_id    uuid NOT NULL REFERENCES sweep(id) ON DELETE CASCADE,
  result      finding NOT NULL,
  asset_id    uuid REFERENCES asset(id) ON DELETE SET NULL,
  epc         citext,
  home_id     uuid REFERENCES location(id) ON DELETE SET NULL,
  rssi        smallint,
  nbv         numeric(14,2),          -- as at the sweep's valued_as_on
  photo_id    uuid,
  condition   text,
  note        text,
  -- For 'eyeballed': who put their name to having seen it.
  seen_by     uuid REFERENCES person(id) ON DELETE SET NULL,
  CONSTRAINT row_identifies_something CHECK (asset_id IS NOT NULL OR epc IS NOT NULL)
);

CREATE INDEX sweep_row_sweep_idx ON sweep_row (sweep_id);
CREATE INDEX sweep_row_asset_idx ON sweep_row (asset_id, result);

-- A shift ends mid-area more often than not. The report has to name everyone
-- whose reads are in the count, not just whoever pressed save.
CREATE TABLE sweep_handover (
  id         bigserial PRIMARY KEY,
  sweep_id   uuid NOT NULL REFERENCES sweep(id) ON DELETE CASCADE,
  from_id    uuid NOT NULL REFERENCES person(id) ON DELETE RESTRICT,
  to_id      uuid NOT NULL REFERENCES person(id) ON DELETE RESTRICT,
  at         timestamptz NOT NULL DEFAULT now(),
  reads_at_handover integer NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------
-- Jobs
-- ---------------------------------------------------------------------

CREATE TABLE task (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id      uuid NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
  type         task_type NOT NULL,
  status       task_status NOT NULL DEFAULT 'open',
  priority     smallint NOT NULL DEFAULT 2 CHECK (priority BETWEEN 1 AND 3),

  asset_id     uuid REFERENCES asset(id) ON DELETE CASCADE,
  epc          citext,
  expected_id  uuid REFERENCES location(id) ON DELETE SET NULL,
  found_id     uuid REFERENCES location(id) ON DELETE SET NULL,
  round_id     uuid REFERENCES audit_round(id) ON DELETE SET NULL,
  sweep_id     uuid REFERENCES sweep(id) ON DELETE SET NULL,

  team_id      uuid REFERENCES team(id) ON DELETE SET NULL,
  assignee_id  uuid REFERENCES person(id) ON DELETE SET NULL,

  raised_at    timestamptz NOT NULL DEFAULT now(),
  due_at       timestamptz,
  closed_at    timestamptz,
  closed_by    uuid REFERENCES person(id) ON DELETE SET NULL,
  resolution   text,
  remarks      text,

  rev          integer NOT NULL DEFAULT 1,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- One open job per asset per type. In the browser build this was deduplicated
-- in JavaScript against that device's own copy, so four handhelds finishing
-- four areas each raised their own Return job for the same wandering trolley.
CREATE UNIQUE INDEX task_one_open_per_asset
  ON task (asset_id, type)
  WHERE status <> 'closed' AND asset_id IS NOT NULL;

CREATE INDEX task_open_idx ON task (site_id, status) WHERE status <> 'closed';
CREATE INDEX task_due_idx  ON task (due_at) WHERE status <> 'closed';

CREATE TABLE task_history (
  id        bigserial PRIMARY KEY,
  task_id   uuid NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  at        timestamptz NOT NULL DEFAULT now(),
  actor_id  uuid REFERENCES person(id) ON DELETE SET NULL,
  actor_name text NOT NULL,            -- kept verbatim; people leave
  what      text NOT NULL
);

CREATE INDEX task_history_task_idx ON task_history (task_id, at);

-- ---------------------------------------------------------------------
-- Tag replacements — append-only
--
-- Replacing a tag moves the identity of an asset onto a different tag. Do it
-- and the register agrees the asset is wherever the new tag goes. It is the
-- most forgeable action in the system, so it carries a reason, a signature,
-- and the old tag stays on the record.
-- ---------------------------------------------------------------------

CREATE TABLE retag (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id     uuid NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
  batch_ref   uuid,                    -- one signature may cover a re-label
  asset_id    uuid NOT NULL REFERENCES asset(id) ON DELETE RESTRICT,
  asset_code  citext NOT NULL,         -- frozen: the code may later change
  asset_name  text,
  old_epc     citext NOT NULL,
  new_epc     citext NOT NULL,
  reason      retag_reason NOT NULL,
  remarks     text,
  by_id       uuid NOT NULL REFERENCES person(id) ON DELETE RESTRICT,
  by_name     text NOT NULL,
  by_role     user_role NOT NULL,
  -- True only when the person re-entered their PIN and it verified. The
  -- correction path during a verification pass records false, and the report
  -- shows it as unsigned rather than pretending otherwise.
  signed      boolean NOT NULL,
  at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT retag_actually_changes_the_tag CHECK (old_epc <> new_epc)
);

CREATE INDEX retag_asset_idx ON retag (asset_id, at DESC);
-- A replaced tag is dead, not unknown. If it is read in a later sweep this
-- index is how it gets named: "came off AST-1014 in March, Deepa replaced it
-- because it was damaged, go and destroy it."
CREATE INDEX retag_old_epc_idx ON retag (site_id, old_epc);

CREATE TRIGGER retag_append_only
  BEFORE UPDATE OR DELETE ON retag
  FOR EACH ROW EXECUTE FUNCTION deny_change();

-- ---------------------------------------------------------------------
-- Change log — append-only
--
-- The auditor's first question is never "what does it say now" but "who
-- changed it, when, and what did it say before". In the browser build this
-- aged out at 2,000 entries and the application could rewrite it. Here it
-- does neither.
-- ---------------------------------------------------------------------

CREATE TABLE change_log (
  id          bigserial PRIMARY KEY,
  site_id     uuid NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
  at          timestamptz NOT NULL DEFAULT now(),
  actor_id    uuid REFERENCES person(id) ON DELETE SET NULL,
  actor_name  text NOT NULL,
  actor_role  user_role,
  entity      text NOT NULL,           -- 'asset', 'asset_class', ...
  entity_id   uuid,
  label       text,                    -- human-readable, frozen at write time
  action      text NOT NULL CHECK (action IN ('created','changed','removed')),
  field       text,
  old_value   text,
  new_value   text
);

CREATE INDEX change_log_at_idx     ON change_log (site_id, at DESC);
CREATE INDEX change_log_entity_idx ON change_log (entity, entity_id, at DESC);
CREATE INDEX change_log_actor_idx  ON change_log (actor_id, at DESC);

CREATE TRIGGER change_log_append_only
  BEFORE UPDATE OR DELETE ON change_log
  FOR EACH ROW EXECUTE FUNCTION deny_change();

-- Sign-ins and exports. The browser build recorded neither, so you could see
-- what a person changed but not that they were ever in the system, and a
-- failed PIN left no trace at all — which matters most for the read-only
-- auditor role, whose one risky action is downloading the whole register.
CREATE TABLE access_log (
  id         bigserial PRIMARY KEY,
  site_id    uuid REFERENCES site(id) ON DELETE SET NULL,
  at         timestamptz NOT NULL DEFAULT now(),
  actor_id   uuid REFERENCES person(id) ON DELETE SET NULL,
  actor_name text,
  event      text NOT NULL,            -- sign_in, sign_in_failed, sign_out, export
  detail     text,
  device     text,
  ip         inet
);

CREATE INDEX access_log_at_idx ON access_log (at DESC);

CREATE TRIGGER access_log_append_only
  BEFORE UPDATE OR DELETE ON access_log
  FOR EACH ROW EXECUTE FUNCTION deny_change();

-- ---------------------------------------------------------------------
-- Photographs
--
-- Stored as references. A data URL in a row is how the browser build hit its
-- ceiling at twenty-two photographs; the bytes belong in object storage or on
-- disk, with the row holding the path and the provenance.
-- ---------------------------------------------------------------------

CREATE TABLE photo (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id    uuid NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
  kind       text NOT NULL,            -- audit, asset, evidence
  caption    text,
  storage_key text NOT NULL,           -- path or object key, not the bytes
  bytes      integer,
  taken_by   uuid REFERENCES person(id) ON DELETE SET NULL,
  taken_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE asset_photo (
  asset_id uuid NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
  photo_id uuid NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
  PRIMARY KEY (asset_id, photo_id)
);

-- ---------------------------------------------------------------------
-- Tag stock
-- ---------------------------------------------------------------------

CREATE TABLE tag_batch (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id    uuid NOT NULL REFERENCES site(id) ON DELETE RESTRICT,
  code       citext NOT NULL,
  supplier   text,
  epc_from   citext,
  epc_to     citext,
  qty        integer CHECK (qty > 0),
  received_at date,
  rev        integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, code)
);

CREATE TABLE tag_issue (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id   uuid REFERENCES tag_batch(id) ON DELETE RESTRICT,
  team_id    uuid REFERENCES team(id) ON DELETE SET NULL,
  person_id  uuid REFERENCES person(id) ON DELETE RESTRICT,
  qty        integer NOT NULL CHECK (qty > 0),
  epc_from   citext,
  epc_to     citext,
  issued_by  uuid REFERENCES person(id) ON DELETE RESTRICT,
  at         timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- rev triggers on every mutable table
-- ---------------------------------------------------------------------

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'site','team','person','location','asset_class','asset',
    'audit_round','sweep','task','tag_batch'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER %I_rev BEFORE UPDATE ON %I
         FOR EACH ROW EXECUTE FUNCTION bump_rev()', t, t);
  END LOOP;
END $$;

COMMIT;

-- =====================================================================
-- TagTrail — functions and views
--
-- What lives here is the work the client must not be trusted with: the
-- signature check, the reference generator, the depreciation arithmetic the
-- statutory report depends on, and the classification of a tag read.
--
-- Depreciation in particular is deliberately a function rather than a stored
-- number. A stored net block goes stale the moment anyone changes a useful
-- life, and nothing tells you which rows are now wrong. Computed from cost
-- and date on every read, it cannot drift.
-- =====================================================================

BEGIN;
SET search_path TO tagtrail, public;

-- ---------------------------------------------------------------------
-- Signatures
-- ---------------------------------------------------------------------

-- The PIN never leaves the database in either direction: set_pin takes a
-- plaintext and stores only a bcrypt hash; verify_pin takes a plaintext and
-- returns a boolean. The API holds neither.
CREATE OR REPLACE FUNCTION set_pin(p_person uuid, p_pin text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_pin IS NULL OR length(btrim(p_pin)) < 4 THEN
    RAISE EXCEPTION 'a PIN must be at least 4 characters' USING ERRCODE = '22023';
  END IF;
  UPDATE person
     SET pin_hash = crypt(p_pin, gen_salt('bf', 10)), rev = 0
   WHERE id = p_person;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no such person: %', p_person USING ERRCODE = '02000';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION verify_pin(p_person uuid, p_pin text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT COALESCE(pin_hash = crypt(p_pin, pin_hash), false)
    FROM person
   WHERE id = p_person AND active AND pin_hash IS NOT NULL;
$$;

-- A person with no PIN cannot sign anything, and in the browser build they
-- could also sign *in* with no credential at all. The API asks this first.
CREATE OR REPLACE FUNCTION can_sign(p_person uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT COALESCE(pin_hash IS NOT NULL AND active, false)
    FROM person WHERE id = p_person;
$$;

-- ---------------------------------------------------------------------
-- Audit references
--
-- The browser build generated these by counting existing rows and adding
-- one, so two supervisors opening an audit in the same month both got
-- AUD-2026-10-003. A sequence per site and month, taken under a lock,
-- cannot collide.
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ref_counter (
  site_id uuid NOT NULL REFERENCES site(id) ON DELETE CASCADE,
  period  text NOT NULL,              -- 'AUD-2026-10'
  n       integer NOT NULL DEFAULT 0,
  PRIMARY KEY (site_id, period)
);

CREATE OR REPLACE FUNCTION next_round_ref(p_site uuid, p_when timestamptz DEFAULT now())
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_period text := 'AUD-' || to_char(p_when AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM');
  v_n integer;
BEGIN
  INSERT INTO ref_counter (site_id, period, n)
       VALUES (p_site, v_period, 1)
  ON CONFLICT (site_id, period)
    DO UPDATE SET n = ref_counter.n + 1
    RETURNING n INTO v_n;
  RETURN v_period || '-' || lpad(v_n::text, 3, '0');
END $$;

-- ---------------------------------------------------------------------
-- Depreciation — Schedule II, Companies Act 2013
--
-- Pro-rata from the date put to use, down to a residual floor. The per-asset
-- override wins over the class; the class is what normally decides.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION dep_params(p_asset uuid)
RETURNS TABLE (life smallint, method dep_method, residual_pct numeric, it_rate_pct numeric)
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(a.life_override, c.useful_life),
         COALESCE(a.method_override, c.method, 'SLM'::dep_method),
         COALESCE(a.residual_override, c.residual_pct, 5.00),
         c.it_rate_pct
    FROM asset a LEFT JOIN asset_class c ON c.id = a.class_id
   WHERE a.id = p_asset;
$$;

-- Net block as at a date. Returns null when the register does not yet hold
-- enough to compute one — a cost, a date put to use and a life. Reporting a
-- zero there would be a lie; reporting nothing is the truth.
CREATE OR REPLACE FUNCTION net_block(p_asset uuid, p_as_on date DEFAULT current_date)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE
  a      record;
  prm    record;
  v_days numeric;
  v_res  numeric;
  v_dep  numeric;
  v_rate numeric;
BEGIN
  SELECT cost, in_use_date, status INTO a FROM asset WHERE id = p_asset;
  IF NOT FOUND OR a.cost IS NULL OR a.in_use_date IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO prm FROM dep_params(p_asset);
  IF prm.life IS NULL OR prm.life <= 0 THEN RETURN NULL; END IF;
  IF p_as_on < a.in_use_date THEN RETURN a.cost; END IF;

  v_res  := a.cost * prm.residual_pct / 100.0;
  v_days := p_as_on - a.in_use_date;

  IF prm.method = 'SLM' THEN
    v_dep := (a.cost - v_res) * (v_days / (prm.life * 365.25));
    RETURN GREATEST(a.cost - v_dep, v_res);
  ELSE
    -- Written down value: the rate that takes cost to the residual over the
    -- useful life, applied to the reducing balance.
    v_rate := 1 - power(prm.residual_pct / 100.0, 1.0 / prm.life);
    RETURN GREATEST(a.cost * power(1 - v_rate, v_days / 365.25), v_res);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION accumulated_dep(p_asset uuid, p_as_on date DEFAULT current_date)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN net_block(p_asset, p_as_on) IS NULL THEN NULL
              ELSE (SELECT cost FROM asset WHERE id = p_asset) - net_block(p_asset, p_as_on)
         END;
$$;

-- ---------------------------------------------------------------------
-- Classifying a read
--
-- The order matters and encodes the floor's reality: an asset flagged mobile
-- is never misplaced, one away from the plant is never missing, and a tag
-- that was replaced is dead rather than unknown.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION classify_read(p_site uuid, p_location uuid, p_epc citext)
RETURNS TABLE (result finding, asset_id uuid, home_id uuid, detail text)
LANGUAGE plpgsql STABLE AS $$
-- The OUT parameters asset_id and home_id have the same names as the columns
-- they come from, and plpgsql resolves the variable first. Without this the
-- function raises "column reference is ambiguous" the first time it runs.
#variable_conflict use_column
DECLARE a record; r record;
BEGIN
  SELECT ast.id AS id, ast.home_id AS home_id, ast.mobile AS mobile, ast.status AS status
    INTO a
    FROM asset ast
   WHERE ast.site_id = p_site AND ast.epc = p_epc
     AND ast.status NOT IN ('scrapped','written_off');

  IF FOUND THEN
    -- Status is checked before the home area on purpose. An asset the register
    -- says is at a vendor, read on site, is not simply "in place": it came back
    -- and nobody updated the record. Calling that in place would hide the one
    -- thing the sweep just discovered, and the asset would keep appearing as
    -- away from the plant — excluded from verification — indefinitely.
    IF a.status IN ('at_repair','on_loan','in_transit') THEN
      RETURN QUERY SELECT 'offsite'::finding, a.id, a.home_id,
        format('read here, but the register says %s — it is back, and the record needs updating',
               replace(a.status::text,'_',' '));
    ELSIF a.home_id = p_location THEN
      RETURN QUERY SELECT 'inplace'::finding, a.id, a.home_id, NULL::text;
    ELSIF a.mobile THEN
      RETURN QUERY SELECT 'away'::finding, a.id, a.home_id, 'moves between areas by design';
    ELSE
      RETURN QUERY SELECT 'misplaced'::finding, a.id, a.home_id, NULL::text;
    END IF;
    RETURN;
  END IF;

  SELECT rt.asset_code AS asset_code, rt.at AS at, rt.by_name AS by_name, rt.reason AS reason
    INTO r
    FROM retag rt
   WHERE rt.site_id = p_site AND rt.old_epc = p_epc
   ORDER BY rt.at DESC LIMIT 1;

  IF FOUND THEN
    RETURN QUERY SELECT 'retired'::finding, NULL::uuid, NULL::uuid,
      format('came off %s on %s, replaced by %s (%s) — destroy it',
             r.asset_code, to_char(r.at,'DD Mon YYYY'), r.by_name, r.reason);
    RETURN;
  END IF;

  RETURN QUERY SELECT 'unknown'::finding, NULL::uuid, NULL::uuid, NULL::text;
END $$;

-- ---------------------------------------------------------------------
-- Cross-reads
--
-- UHF at 24 dBm reads through plasterboard. The same asset confirmed in its
-- own area at 09:00 and bled through next door at 11:00 is physics, not a
-- movement, and raising a Return job against a team for it is how an
-- exception list loses its readers. This reports the contradictions in a
-- round so the commit can mark them instead of raising work.
-- ---------------------------------------------------------------------

CREATE OR REPLACE VIEW cross_read_candidates AS
SELECT  s2.round_id,
        sr2.asset_id,
        a.code              AS asset_code,
        s2.location_id      AS read_in,
        a.home_id           AS belongs_to,
        sr2.rssi            AS rssi_away,
        sr1.rssi            AS rssi_home,
        s1.ended_at         AS confirmed_home_at,
        s2.ended_at         AS read_away_at,
        EXISTS (SELECT 1 FROM location_adjacency la
                 WHERE la.location_id = s2.location_id
                   AND la.neighbour_id = a.home_id) AS areas_adjacent
  FROM sweep_row sr2
  JOIN sweep     s2  ON s2.id = sr2.sweep_id
  JOIN asset     a   ON a.id  = sr2.asset_id
  -- the same asset, confirmed in its own area, in the same audit
  JOIN sweep_row sr1 ON sr1.asset_id = sr2.asset_id AND sr1.result = 'inplace'
  JOIN sweep     s1  ON s1.id = sr1.sweep_id
                    AND s1.round_id = s2.round_id
                    AND s1.location_id = a.home_id
 WHERE sr2.result = 'misplaced'
   AND s1.committed AND s2.committed;

-- ---------------------------------------------------------------------
-- The population a report must state
--
-- Coverage used to be read against the expected count, and the expected
-- count quietly leaves out every untagged asset and every mobile one. A line
-- with 300 register assets, 40 never tagged, reported "248 of 248 — 100%".
-- That is a verification certificate for a population narrowed by 17%, and
-- the auditor samples from the register, not from our expected list.
-- ---------------------------------------------------------------------

CREATE OR REPLACE VIEW area_population AS
SELECT l.id   AS location_id,
       l.site_id,
       count(*) FILTER (WHERE a.status NOT IN ('scrapped','written_off'))          AS on_register,
       count(*) FILTER (WHERE a.epc IS NULL
                          AND a.status NOT IN ('scrapped','written_off'))          AS untagged,
       count(*) FILTER (WHERE a.mobile
                          AND a.status NOT IN ('scrapped','written_off'))          AS mobile,
       count(*) FILTER (WHERE a.status IN ('at_repair','on_loan','in_transit'))    AS offsite,
       count(*) FILTER (WHERE a.status IN ('scrapped','written_off'))              AS retired,
       count(*) FILTER (WHERE a.epc IS NOT NULL AND NOT a.mobile
                          AND a.status = 'active')                                 AS expected_by_reader
  FROM location l
  LEFT JOIN asset a ON a.home_id = l.id
 GROUP BY l.id, l.site_id;

-- Assets out for repair past their return date. "Out for repair" must not
-- become a parking space for anything inconvenient.
CREATE OR REPLACE VIEW overdue_returns AS
SELECT a.id, a.site_id, a.code, a.name, a.status, a.status_note,
       a.due_back, current_date - a.due_back AS days_overdue,
       l.code AS home_code, l.name AS home_name
  FROM asset a LEFT JOIN location l ON l.id = a.home_id
 WHERE a.status IN ('at_repair','on_loan','in_transit')
   AND a.due_back IS NOT NULL
   AND a.due_back < current_date;

-- How long an asset has been unaccounted for. An asset missing since 2019
-- with a provision already made and one that went missing this quarter are
-- not the same number, and the browser build reported them as one.
CREATE OR REPLACE VIEW missing_streak AS
SELECT sr.asset_id,
       count(*)              AS consecutive_sweeps,
       min(s.ended_at)       AS missing_since,
       max(s.ended_at)       AS last_confirmed_missing
  FROM sweep_row sr
  JOIN sweep s ON s.id = sr.sweep_id AND s.committed
 WHERE sr.result = 'missing'
 GROUP BY sr.asset_id;

COMMIT;

-- =====================================================================
-- The API's own statements, executed with real data.
--
-- PREPARE proves a statement parses. It does not prove a CTE does what the
-- author thought. These are the four where a wrong assumption would fail
-- silently rather than loudly — the worst kind.
-- =====================================================================
\set ON_ERROR_STOP off
SET search_path TO tagtrail, public;

\echo '--- fixtures ---'
INSERT INTO site (code,name) VALUES ('PLT-B','Plant B') ON CONFLICT DO NOTHING;
INSERT INTO person (site_id,emp_code,name,role)
  SELECT id,'EMP-A','Arun','admin' FROM site WHERE code='PLT-B' ON CONFLICT DO NOTHING;
INSERT INTO person (site_id,emp_code,name,role)
  SELECT id,'EMP-D','Deepa','supervisor' FROM site WHERE code='PLT-B' ON CONFLICT DO NOTHING;
SELECT set_pin(id,'1234') FROM person WHERE emp_code='EMP-A';
INSERT INTO location (site_id,code,name)
  SELECT id,'B-ASSY','Assembly B' FROM site WHERE code='PLT-B' ON CONFLICT DO NOTHING;
INSERT INTO asset (site_id,code,name,home_id,epc,cost,in_use_date)
  SELECT s.id,'B-1001','Torque Wrench',l.id,'EPCAAA1',11000,'2024-04-01'
    FROM site s, location l WHERE s.code='PLT-B' AND l.code='B-ASSY' ON CONFLICT DO NOTHING;
INSERT INTO asset (site_id,code,name,home_id,epc,cost,in_use_date)
  SELECT s.id,'B-1002','Clamp Meter',l.id,'EPCAAA2',9000,'2024-04-01'
    FROM site s, location l WHERE s.code='PLT-B' AND l.code='B-ASSY' ON CONFLICT DO NOTHING;
INSERT INTO audit_round (site_id,ref,title,reason,opened_by)
  SELECT s.id,next_round_ref(s.id),'B half-yearly','annual',p.id
    FROM site s, person p WHERE s.code='PLT-B' AND p.emp_code='EMP-A';
INSERT INTO round_scope (round_id,location_id)
  SELECT r.id,l.id FROM audit_round r, location l
   WHERE r.title='B half-yearly' AND l.code='B-ASSY';
INSERT INTO sweep (site_id,round_id,location_id,operator_id,started_at,rssi_floor,expected_n,register_n)
  SELECT s.id,r.id,l.id,p.id,now(),-70,2,2
    FROM site s, audit_round r, location l, person p
   WHERE s.code='PLT-B' AND r.title='B half-yearly' AND l.code='B-ASSY' AND p.emp_code='EMP-A';

\echo ''
\echo '=== A. UpsertReads: a batch lands, and a repeat accumulates ==='
INSERT INTO sweep_read (sweep_id, epc, rssi_max, rssi_med, read_count, first_at, last_at)
SELECT (SELECT id FROM sweep WHERE NOT committed LIMIT 1), r.epc, r.rssi, r.rssi, 1, now(), now()
  FROM unnest(ARRAY['EPCAAA1','EPCAAA2']::citext[], ARRAY[-55,-61]::smallint[]) AS r(epc, rssi)
ON CONFLICT (sweep_id, epc) DO UPDATE
   SET rssi_max   = GREATEST(sweep_read.rssi_max, EXCLUDED.rssi_max),
       rssi_med   = (sweep_read.rssi_med * sweep_read.read_count + EXCLUDED.rssi_max)
                    / (sweep_read.read_count + 1),
       read_count = sweep_read.read_count + 1,
       last_at    = now();
-- the same tag again, much weaker: the max must not fall, the median must
INSERT INTO sweep_read (sweep_id, epc, rssi_max, rssi_med, read_count, first_at, last_at)
SELECT (SELECT id FROM sweep WHERE NOT committed LIMIT 1), r.epc, r.rssi, r.rssi, 1, now(), now()
  FROM unnest(ARRAY['EPCAAA1']::citext[], ARRAY[-85]::smallint[]) AS r(epc, rssi)
ON CONFLICT (sweep_id, epc) DO UPDATE
   SET rssi_max   = GREATEST(sweep_read.rssi_max, EXCLUDED.rssi_max),
       rssi_med   = (sweep_read.rssi_med * sweep_read.read_count + EXCLUDED.rssi_max)
                    / (sweep_read.read_count + 1),
       read_count = sweep_read.read_count + 1,
       last_at    = now();
SELECT epc, rssi_max, rssi_med, read_count FROM sweep_read ORDER BY epc;
\echo 'expect: EPCAAA1 max -55 (unchanged), med about -70, count 2'

\echo ''
\echo '=== B. RecordHandover: the CTE must actually move the sweep ==='
SELECT operator_id = (SELECT id FROM person WHERE emp_code='EMP-A') AS "starts as Arun"
  FROM sweep WHERE NOT committed;
WITH h AS (
  INSERT INTO sweep_handover (sweep_id, from_id, to_id, reads_at_handover)
  SELECT s.id, s.operator_id, (SELECT id FROM person WHERE emp_code='EMP-D'),
         (SELECT count(*) FROM sweep_read r WHERE r.sweep_id = s.id)
    FROM sweep s
   WHERE s.id = (SELECT id FROM sweep WHERE NOT committed LIMIT 1)
     AND s.operator_id <> (SELECT id FROM person WHERE emp_code='EMP-D')
  RETURNING sweep_id
)
UPDATE sweep SET operator_id = (SELECT id FROM person WHERE emp_code='EMP-D'), rev = 0
 WHERE id = (SELECT sweep_id FROM h)
RETURNING operator_id;
SELECT p.name AS "now held by", h.reads_at_handover, pf.name AS "handed over from"
  FROM sweep s
  JOIN person p ON p.id = s.operator_id
  LEFT JOIN sweep_handover h ON h.sweep_id = s.id
  LEFT JOIN person pf ON pf.id = h.from_id
 WHERE NOT s.committed;
\echo 'expect: now held by Deepa, handed over from Arun, 2 reads at handover'

\echo ''
\echo '=== C. RaiseTask: a second identical job bumps priority, never duplicates ==='
INSERT INTO task (site_id,type,asset_id,epc,expected_id,round_id,sweep_id,due_at)
SELECT s.id,'locate',a.id,a.epc,a.home_id,r.id,sw.id, now() + interval '7 days'
  FROM site s, asset a, audit_round r, sweep sw
 WHERE s.code='PLT-B' AND a.code='B-1001' AND r.title='B half-yearly' AND NOT sw.committed
ON CONFLICT (asset_id, type) WHERE status <> 'closed' AND asset_id IS NOT NULL
DO UPDATE SET priority = LEAST(3, task.priority + 1), rev = 0
RETURNING id, priority, (xmax = 0) AS was_new;
INSERT INTO task (site_id,type,asset_id,epc,expected_id,round_id,sweep_id,due_at)
SELECT s.id,'locate',a.id,a.epc,a.home_id,r.id,sw.id, now() + interval '7 days'
  FROM site s, asset a, audit_round r, sweep sw
 WHERE s.code='PLT-B' AND a.code='B-1001' AND r.title='B half-yearly' AND NOT sw.committed
ON CONFLICT (asset_id, type) WHERE status <> 'closed' AND asset_id IS NOT NULL
DO UPDATE SET priority = LEAST(3, task.priority + 1), rev = 0
RETURNING id, priority, (xmax = 0) AS was_new;
SELECT count(*) AS "locate jobs for B-1001", max(priority) AS priority
  FROM task WHERE asset_id = (SELECT id FROM asset WHERE code='B-1001') AND type='locate';
\echo 'expect: one row, was_new f on the second, priority raised to 3'

\echo ''
\echo '=== D. ApplyRetag: a wrong PIN must move nothing at all ==='
SELECT code, epc AS "before" FROM asset WHERE code='B-1001';
WITH signed AS (
  SELECT verify_pin((SELECT id FROM person WHERE emp_code='EMP-A'), '9999') AS ok
), moved AS (
  UPDATE asset
     SET epc='EPCNEW1', tagged_at=now(),
         tagged_by=(SELECT id FROM person WHERE emp_code='EMP-A'),
         retag_count=retag_count+1, rev=0
   WHERE code='B-1001' AND epc='EPCAAA1' AND (SELECT ok FROM signed)
  RETURNING id, code, name
)
INSERT INTO retag (site_id,asset_id,asset_code,asset_name,old_epc,new_epc,reason,by_id,by_name,by_role,signed)
SELECT (SELECT id FROM site WHERE code='PLT-B'), m.id, m.code, m.name,
       'EPCAAA1','EPCNEW1','damaged', p.id, p.name, p.role, true
  FROM moved m, person p WHERE p.emp_code='EMP-A'
RETURNING id;
SELECT code, epc AS "after a wrong PIN", retag_count FROM asset WHERE code='B-1001';
SELECT count(*) AS "retag records written" FROM retag WHERE asset_code='B-1001';
\echo 'expect: 0 rows returned, epc still EPCAAA1, retag_count 0, 0 records'

\echo ''
\echo '=== D2. ApplyRetag: the right PIN moves the tag and writes the record, together ==='
WITH signed AS (
  SELECT verify_pin((SELECT id FROM person WHERE emp_code='EMP-A'), '1234') AS ok
), moved AS (
  UPDATE asset
     SET epc='EPCNEW1', tagged_at=now(),
         tagged_by=(SELECT id FROM person WHERE emp_code='EMP-A'),
         retag_count=retag_count+1, rev=0
   WHERE code='B-1001' AND epc='EPCAAA1' AND (SELECT ok FROM signed)
  RETURNING id, code, name
)
INSERT INTO retag (site_id,asset_id,asset_code,asset_name,old_epc,new_epc,reason,by_id,by_name,by_role,signed)
SELECT (SELECT id FROM site WHERE code='PLT-B'), m.id, m.code, m.name,
       'EPCAAA1','EPCNEW1','damaged', p.id, p.name, p.role, true
  FROM moved m, person p WHERE p.emp_code='EMP-A'
RETURNING id;
SELECT code, epc AS "after the right PIN", retag_count FROM asset WHERE code='B-1001';
SELECT asset_code, old_epc, new_epc, reason, signed FROM retag WHERE asset_code='B-1001';
\echo 'expect: one record, epc now EPCNEW1, retag_count 1, signed t'

\echo ''
\echo '=== E. The old tag, read in a later sweep, is named ==='
SELECT result, detail FROM classify_read(
  (SELECT id FROM site WHERE code='PLT-B'),
  (SELECT id FROM location WHERE code='B-ASSY'), 'EPCAAA1');
\echo 'expect: retired, naming B-1001, the date, Arun and the reason'

\echo ''
\echo '=== F. The report states the register, not just what the reader saw ==='
UPDATE asset SET epc=NULL, rev=0 WHERE code='B-1002';           -- never tagged
INSERT INTO asset (site_id,code,name,home_id,epc,cost,in_use_date,mobile)
  SELECT s.id,'B-1003','Site Laptop',l.id,'EPCAAA3',60000,'2024-04-01',true
    FROM site s, location l WHERE s.code='PLT-B' AND l.code='B-ASSY';
SELECT on_register, untagged, mobile, offsite, expected_by_reader
  FROM area_population WHERE location_id = (SELECT id FROM location WHERE code='B-ASSY');
\echo 'expect: on_register 3, untagged 1, mobile 1, expected_by_reader 1'

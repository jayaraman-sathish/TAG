-- =====================================================================
-- Does the database actually enforce what it claims?
--
-- Each block tries to do the wrong thing and expects to be stopped. A schema
-- that merely parses proves nothing; these are the guarantees the browser
-- build could not make, so they are the ones worth testing.
-- =====================================================================
\set ON_ERROR_STOP off
SET search_path TO tagtrail, public;

\echo '--- setup ---'
INSERT INTO site (code,name) VALUES ('PLT-A','Plant A') ON CONFLICT DO NOTHING;
INSERT INTO team (site_id,code,name)
  SELECT id,'MAINT','Plant Maintenance' FROM site WHERE code='PLT-A' ON CONFLICT DO NOTHING;
INSERT INTO person (site_id,emp_code,name,role)
  SELECT id,'EMP-0301','Arun Prakash','admin' FROM site WHERE code='PLT-A' ON CONFLICT DO NOTHING;
INSERT INTO person (site_id,emp_code,name,role)
  SELECT id,'EMP-1042','S. Kumar','operator' FROM site WHERE code='PLT-A' ON CONFLICT DO NOTHING;
INSERT INTO location (site_id,code,name)
  SELECT id,'PLT-A-ASSY','Assembly Bay A' FROM site WHERE code='PLT-A' ON CONFLICT DO NOTHING;
INSERT INTO location (site_id,code,name)
  SELECT id,'PLT-A-CRIB','Tool Crib' FROM site WHERE code='PLT-A' ON CONFLICT DO NOTHING;
INSERT INTO asset_class (site_id,code,name,useful_life,method,it_rate_pct)
  SELECT id,'PM-GEN','Plant & machinery (general)',15,'SLM',15 FROM site WHERE code='PLT-A' ON CONFLICT DO NOTHING;
INSERT INTO asset (site_id,code,name,home_id,class_id,epc,cost,in_use_date)
  SELECT s.id,'AST-1001','Digital Torque Wrench',l.id,c.id,'E28011709E3779B1FBD64A0E',13000,'2024-04-01'
    FROM site s, location l, asset_class c
   WHERE s.code='PLT-A' AND l.code='PLT-A-ASSY' AND c.code='PM-GEN' ON CONFLICT DO NOTHING;

\echo ''
\echo '=== 1. A PIN is never stored in the clear, and is verified in the database ==='
SELECT set_pin(id,'1234') FROM person WHERE emp_code='EMP-0301';
SELECT emp_code,
       pin_hash LIKE '$2%'                       AS "stored as bcrypt",
       pin_hash = '1234'                         AS "equals the pin",
       verify_pin(id,'1234')                     AS "correct pin verifies",
       verify_pin(id,'9999')                     AS "wrong pin verifies"
  FROM person WHERE emp_code='EMP-0301';
\echo 'expect: bcrypt=t, equals=f, correct=t, wrong=f'

\echo ''
\echo '=== 2. A person with no PIN cannot sign a tag replacement ==='
SELECT emp_code, can_sign(id) AS "can sign" FROM person ORDER BY emp_code;
\echo 'expect: EMP-0301 t (pin set), EMP-1042 f (no pin)'

\echo ''
\echo '=== 3. Audit references cannot collide ==='
SELECT next_round_ref(id) AS ref FROM site WHERE code='PLT-A';
SELECT next_round_ref(id) AS ref FROM site WHERE code='PLT-A';
SELECT next_round_ref(id) AS ref FROM site WHERE code='PLT-A';
\echo 'expect: three different refs, -001 -002 -003'

\echo ''
\echo '=== 4. The change log cannot be rewritten or deleted ==='
INSERT INTO change_log (site_id,actor_name,entity,entity_id,label,action,field,old_value,new_value)
  SELECT id,'Arun Prakash','asset',NULL,'AST-1001','changed','cost','13000','450000' FROM site WHERE code='PLT-A';
UPDATE change_log SET new_value='1' WHERE field='cost';
\echo '^ expect: ERROR, append-only'
DELETE FROM change_log WHERE field='cost';
\echo '^ expect: ERROR, append-only'
SELECT count(*) AS "log rows still there" FROM change_log;

\echo ''
\echo '=== 5. A tag replacement cannot be rewritten ==='
INSERT INTO retag (site_id,asset_id,asset_code,old_epc,new_epc,reason,by_id,by_name,by_role,signed)
  SELECT s.id,a.id,a.code,'E28011709E3779B1FBD64A0E','E28011700000000000009999','damaged',
         p.id,p.name,p.role,true
    FROM site s, asset a, person p
   WHERE s.code='PLT-A' AND a.code='AST-1001' AND p.emp_code='EMP-0301';
UPDATE retag SET reason='wrong';
\echo '^ expect: ERROR, append-only'

\echo ''
\echo '=== 6. A replaced tag read later is named, not anonymous ==='
-- The replacement itself: the asset moves onto the new tag. Without this the
-- old EPC is still live and the answer would (correctly) be 'inplace'.
UPDATE asset SET epc='E28011700000000000009999', retag_count=retag_count+1, rev=0
 WHERE code='AST-1001';
SELECT result, detail
  FROM classify_read((SELECT id FROM site WHERE code='PLT-A'),
                     (SELECT id FROM location WHERE code='PLT-A-ASSY'),
                     'E28011709E3779B1FBD64A0E');
\echo 'expect: retired, naming the asset, date, person and reason'
SELECT result FROM classify_read((SELECT id FROM site WHERE code='PLT-A'),
                                 (SELECT id FROM location WHERE code='PLT-A-ASSY'),
                                 'E28011700000000000009999');
\echo 'expect: inplace — the new tag is the live one'

\echo ''
\echo '=== 7. Two assets cannot hold the same tag ==='
INSERT INTO asset (site_id,code,name,home_id,epc)
  SELECT s.id,'AST-9999','Impostor',l.id,'E28011700000000000009999'
    FROM site s, location l WHERE s.code='PLT-A' AND l.code='PLT-A-ASSY';
\echo '^ expect: ERROR, duplicate key'

\echo ''
\echo '=== 8. A stale write is rejected instead of overwriting a colleague ==='
-- Both devices read the row at whatever rev it is now; device A commits
-- first, and device B is still holding the rev it read.
SELECT rev FROM asset WHERE code='AST-1001' \gset shared_
UPDATE asset SET cost=450000, rev=:shared_rev WHERE code='AST-1001';   -- device A
SELECT code, cost, rev FROM asset WHERE code='AST-1001';
UPDATE asset SET name='Overwritten by a stale device', rev=:shared_rev
 WHERE code='AST-1001';                                                -- device B
\echo '^ expect: ERROR, stale write (device B still thought it was rev 1)'
SELECT code, name, cost, rev AS "rev after" FROM asset WHERE code='AST-1001';
\echo 'expect: name unchanged, cost 450000, rev bumped once'

\echo ''
\echo '=== 9. An area cannot be deleted out from under a running audit ==='
INSERT INTO audit_round (site_id,ref,title,reason,opened_by)
  SELECT s.id,next_round_ref(s.id),'Half-yearly FY26','annual',p.id
    FROM site s, person p WHERE s.code='PLT-A' AND p.emp_code='EMP-0301';
-- An empty area, so the only thing standing in the way of the delete is the
-- audit scope itself. Deleting one that still holds assets is refused by the
-- asset foreign key, which proves a different guarantee, not this one.
INSERT INTO location (site_id,code,name)
  SELECT id,'PLT-A-OLD','Old Bay (no assets)' FROM site WHERE code='PLT-A';
DELETE FROM location WHERE code='PLT-A-OLD';
\echo '^ expect: success — nothing references it yet'
INSERT INTO location (site_id,code,name)
  SELECT id,'PLT-A-OLD','Old Bay (no assets)' FROM site WHERE code='PLT-A';
INSERT INTO round_scope (round_id,location_id)
  SELECT r.id,l.id FROM audit_round r, location l
   WHERE r.title='Half-yearly FY26' AND l.code='PLT-A-OLD';
DELETE FROM location WHERE code='PLT-A-OLD';
\echo '^ expect: ERROR, round_scope restricts it — this is the real test'
-- And the one that still holds assets, for completeness.
DELETE FROM location WHERE code='PLT-A-ASSY';
\echo '^ expect: ERROR, assets are still allotted to it'

\echo ''
\echo '=== 10. An audit cannot be signed off by the person who opened it ==='
UPDATE audit_round SET signed_off_by = opened_by, signed_off_at = now()
 WHERE title='Half-yearly FY26';
\echo '^ expect: ERROR, signer is not the opener'

\echo ''
\echo '=== 11. due_back only means something while the asset is away ==='
UPDATE asset SET due_back='2026-11-15' WHERE code='AST-1001';
\echo '^ expect: ERROR, asset is active'
UPDATE asset SET status='at_repair', status_note='Calibration lab WO-5512',
                 due_back='2026-11-15', rev=0 WHERE code='AST-1001';
SELECT code,status,due_back FROM asset WHERE code='AST-1001';
\echo 'expect: at_repair with the date accepted'

\echo ''
\echo '=== 12. An asset away from the plant is not expected by the reader ==='
SELECT l.code,
       p.on_register, p.untagged, p.mobile, p.offsite, p.expected_by_reader
  FROM area_population p JOIN location l ON l.id = p.location_id
 WHERE l.code='PLT-A-ASSY';
\echo 'expect: on_register 1, offsite 1, expected_by_reader 0'

\echo ''
\echo '=== 13. Depreciation is computed, never stored stale ==='
UPDATE asset SET status='active', due_back=NULL, rev=0 WHERE code='AST-1001';
SELECT code,
       cost,
       round(net_block(id,'2026-03-31'),2)     AS "net block 31-Mar-26",
       round(accumulated_dep(id,'2026-03-31'),2) AS "accum dep",
       round(net_block(id,'2027-03-31'),2)     AS "net block 31-Mar-27"
  FROM asset WHERE code='AST-1001';
\echo 'expect: net block falls over time, accum dep rises, never below 5% residual'

\echo ''
\echo '=== 14. An asset with a cost but no in-use date is refused ==='
INSERT INTO asset (site_id,code,name,home_id,cost)
  SELECT s.id,'AST-8888','No date',l.id,50000
    FROM site s, location l WHERE s.code='PLT-A' AND l.code='PLT-A-CRIB';
\echo '^ expect: ERROR, depreciation needs a date'

\echo ''
\echo '=== 15. One live sweep per area, so four handhelds cannot double-count ==='
INSERT INTO sweep (site_id,round_id,location_id,operator_id,started_at,rssi_floor)
  SELECT s.id,r.id,l.id,p.id,now(),-70
    FROM site s, audit_round r, location l, person p
   WHERE s.code='PLT-A' AND r.title='Half-yearly FY26'
     AND l.code='PLT-A-CRIB' AND p.emp_code='EMP-0301';
INSERT INTO sweep (site_id,round_id,location_id,operator_id,started_at,rssi_floor)
  SELECT s.id,r.id,l.id,p.id,now(),-70
    FROM site s, audit_round r, location l, person p
   WHERE s.code='PLT-A' AND r.title='Half-yearly FY26'
     AND l.code='PLT-A-CRIB' AND p.emp_code='EMP-1042';
\echo '^ expect: ERROR, a live sweep of that area already exists'

\echo ''
\echo '=== 16. One open job per asset per type, enforced for every device ==='
INSERT INTO task (site_id,type,asset_id,expected_id)
  SELECT s.id,'locate',a.id,a.home_id FROM site s, asset a
   WHERE s.code='PLT-A' AND a.code='AST-1001';
INSERT INTO task (site_id,type,asset_id,expected_id)
  SELECT s.id,'locate',a.id,a.home_id FROM site s, asset a
   WHERE s.code='PLT-A' AND a.code='AST-1001';
\echo '^ expect: ERROR, one open locate job already exists for that asset'

\echo ''
\echo '=== summary ==='
SELECT (SELECT count(*) FROM asset)       AS assets,
       (SELECT count(*) FROM change_log)  AS log_rows,
       (SELECT count(*) FROM retag)       AS retags,
       (SELECT count(*) FROM audit_round) AS rounds,
       (SELECT count(*) FROM task)        AS tasks;

-- =====================================================================
-- TagTrail — seed
--
-- This mirrors the master data in the TagTrail console exactly: the same
-- plant, the same five areas, the same four departments, the same seven
-- people with the same employee codes, and the same twenty-eight assets
-- with the same codes, names and categories.
--
-- That is the whole point. An earlier version of this file invented a
-- different plant with different people, which would have meant the
-- database and the application disagreed about every record the moment
-- they were connected.
--
-- What is added here, and is NOT in the console's own seed: asset classes,
-- costs and dates put to use. Depreciation cannot be computed without them,
-- and in the console they are entered through the UI. The figures below are
-- plausible rather than real — replace them with the client's register.
--
-- Also deliberate: a few assets are left untagged, a few are flagged as
-- moving between areas, and two are away from the plant. A seed where
-- everything is tidy hides the distinctions the system exists to draw.
--
-- Safe to re-run. PINs are 1234 for the three accounts that have one in the
-- console, matching it exactly.
-- =====================================================================

BEGIN;
SET search_path TO tagtrail, public;

-- ---------------------------------------------------------------------
-- Site — "Client site — Plant A" is what the console calls it
-- ---------------------------------------------------------------------
INSERT INTO site (code, name, rssi_floor, tx_power, dwell_ms,
                  sla_locate, sla_return, sla_identify, wo_limit)
VALUES ('PLT-A', 'Client site — Plant A', -70, 24, 400, 7, 3, 5, 25000)
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------
-- Departments — MNT, STO, QAM, ITA, as in the console
-- ---------------------------------------------------------------------
INSERT INTO team (site_id, code, name, lead_name, email)
SELECT s.id, v.code, v.name, v.lead, v.email
  FROM site s, (VALUES
    ('MNT','Plant Maintenance',  'Ravi Menon',   'ravi.menon@client.example'),
    ('STO','Stores & Logistics', 'Sunil Rathod', 'sunil.rathod@client.example'),
    ('QAM','QA & Metrology',     'Deepa Iyer',   'deepa.iyer@client.example'),
    ('ITA','IT & Admin',         'Arun Prakash', 'arun.prakash@client.example')
  ) AS v(code,name,lead,email)
 WHERE s.code='PLT-A'
ON CONFLICT (site_id, code) DO NOTHING;

-- ---------------------------------------------------------------------
-- People — the same seven, with the same employee codes
-- ---------------------------------------------------------------------
INSERT INTO person (site_id, emp_code, name, role)
SELECT s.id, v.emp, v.nm, v.rl::user_role
  FROM site s, (VALUES
    ('EMP-1042','S. Kumar',                        'operator'),
    ('EMP-0871','Ravi Menon',                      'supervisor'),
    ('EMP-0912','Sunil Rathod',                    'supervisor'),
    ('EMP-1188','Deepa Iyer',                      'supervisor'),
    ('EMP-0455','Meera Krishnan',                  'approver'),
    ('EMP-0301','Arun Prakash',                    'admin'),
    ('EXT-0007','N. Venkatesh (Statutory Auditor)','viewer')
  ) AS v(emp,nm,rl)
 WHERE s.code='PLT-A'
ON CONFLICT (site_id, emp_code) DO NOTHING;

UPDATE person p SET team_id = t.id, rev = 0
  FROM team t, (VALUES
    ('EMP-1042','QAM'), ('EMP-0871','MNT'), ('EMP-0912','STO'),
    ('EMP-1188','QAM'), ('EMP-0301','ITA')
  ) AS v(emp,tcode)
 WHERE p.emp_code=v.emp AND t.code=v.tcode AND t.site_id=p.site_id;

-- The console gives a PIN to three accounts and leaves four blank. The API
-- refuses a sign-in without one, because an account that can be used with no
-- credential undermines every "who did this" record in the register. So the
-- four are given one here rather than being left unusable — and that gap is
-- itself worth fixing in the console.
SELECT set_pin(id,'1234') FROM person
 WHERE site_id = (SELECT id FROM site WHERE code='PLT-A');

-- ---------------------------------------------------------------------
-- Areas — the same five
-- ---------------------------------------------------------------------
INSERT INTO location (site_id, code, name, area, team_id, owner_name, email, anchor_epc)
SELECT s.id, v.code, v.name, v.area, t.id, v.owner, v.email, v.anchor
  FROM site s
  CROSS JOIN (VALUES
    ('PLT-A-ASSY','Assembly Bay A',  'Plant A',    'MNT','Ravi Menon',  'ravi.menon@client.example',  'E28011700000000000A00001'),
    ('PLT-A-CRIB','Tool Crib',       'Plant A',    'STO','Ravi Menon',  'ravi.menon@client.example',  'E28011700000000000A00002'),
    ('PLT-A-QA',  'QA Lab',          'Plant A',    'QAM','Deepa Iyer',  'deepa.iyer@client.example',  'E28011700000000000A00003'),
    ('OFC-B-ENG', 'Engineering Bay', 'Office B',   'ITA','Arun Prakash','arun.prakash@client.example','E28011700000000000A00004'),
    ('WH-C-SPR',  'Spares Store',    'Warehouse C','STO','Sunil Rathod','sunil.rathod@client.example','E28011700000000000A00005')
  ) AS v(code,name,area,tcode,owner,email,anchor)
  LEFT JOIN team t ON t.site_id=s.id AND t.code=v.tcode
 WHERE s.code='PLT-A'
ON CONFLICT (site_id, code) DO NOTHING;

-- Assembly Bay A and the Tool Crib are both on Plant A ground floor with a
-- doorway between them, so a reader in one will pick up tags in the other.
-- Recording that is what lets a cross-read be told apart from a movement.
INSERT INTO location_adjacency (location_id, neighbour_id, porosity)
SELECT a.id, b.id, v.p
  FROM (VALUES
    ('PLT-A-ASSY','PLT-A-CRIB',3), ('PLT-A-CRIB','PLT-A-ASSY',3),
    ('PLT-A-QA',  'PLT-A-ASSY',1), ('PLT-A-ASSY','PLT-A-QA',  1)
  ) AS v(a,b,p)
  JOIN location a ON a.code=v.a JOIN location b ON b.code=v.b
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- Asset classes — Schedule II useful lives, Income Tax Act block rates
--
-- Not in the console's seed; added because depreciation cannot be computed
-- without a life and a method, and the register is the point of the exercise.
-- ---------------------------------------------------------------------
INSERT INTO asset_class (site_id, code, name, useful_life, method, residual_pct, it_rate_pct, dept_team_id)
SELECT s.id, v.code, v.name, v.life, v.m::dep_method, 5.00, v.itr, t.id
  FROM site s
  CROSS JOIN (VALUES
    ('PM-GEN',  'Plant & machinery (general)',       15,'SLM',15,'MNT'),
    ('ELEC-INS','Electrical instruments & testers',  10,'SLM',15,'QAM'),
    ('LAB',     'Laboratory & metrology equipment',  10,'SLM',15,'QAM'),
    ('TOOL',    'Tools & fixtures',                   8,'SLM',15,'MNT'),
    ('FURN',    'Furniture & fittings',              10,'SLM',10,'ITA'),
    ('COMP',    'Computers & data processing units',  3,'WDV',40,'ITA'),
    ('MHE',     'Material handling equipment',       12,'SLM',15,'STO')
  ) AS v(code,name,life,m,itr,tcode)
  LEFT JOIN team t ON t.site_id=s.id AND t.code=v.tcode
 WHERE s.code='PLT-A'
ON CONFLICT (site_id, code) DO NOTHING;

-- ---------------------------------------------------------------------
-- Assets — the same twenty-eight, with the console's codes, names,
-- categories and areas. Costs, dates and classes are added here.
-- ---------------------------------------------------------------------
INSERT INTO asset (site_id, code, name, category, home_id, class_id,
                   epc, tagged_at, cost, in_use_date, status, status_note,
                   due_back, mobile)
SELECT s.id, v.code, v.name, v.category, l.id, c.id,
       v.epc, CASE WHEN v.epc IS NULL THEN NULL ELSE now() - interval '180 days' END,
       v.cost, v.in_use::date, v.status::asset_status, v.note, v.due::date, v.mob
  FROM site s
  CROSS JOIN (VALUES
  -- Assembly Bay A
  ('AST-1001','Digital Torque Wrench 5-50Nm','Hand tool','PLT-A-ASSY','TOOL',    'E28011700000000000B01001',  42000,'2022-06-15','active',NULL,NULL,false),
  ('AST-1002','Pneumatic Screwdriver PS-40','Power tool','PLT-A-ASSY','TOOL',    'E28011700000000000B01002',  28000,'2022-06-15','active',NULL,NULL,false),
  ('AST-1003','Assembly Jig Fixture J-12','Fixture','PLT-A-ASSY','TOOL',         'E28011700000000000B01003', 165000,'2021-03-01','active',NULL,NULL,false),
  ('AST-1004','ESD Workbench Station 3','Workstation','PLT-A-ASSY','FURN',       'E28011700000000000B01004',  86000,'2021-03-01','active',NULL,NULL,false),
  ('AST-1005','Label Printer TT-300','Peripheral','PLT-A-ASSY','COMP',           'E28011700000000000B01005',  34000,'2023-09-12','active',NULL,NULL,false),
  ('AST-1006','Torque Analyser TA-2','Instrument','PLT-A-ASSY','ELEC-INS',       'E28011700000000000B01006', 195000,'2020-11-20','active',NULL,NULL,false),
  -- Tool Crib. The testers travel to wherever the work is.
  ('AST-1007','Insulation Tester 1kV','Instrument','PLT-A-CRIB','ELEC-INS',      'E28011700000000000B01007',  78000,'2022-01-18','active',NULL,NULL,true),
  ('AST-1008','Hipot Tester 5kV','Instrument','PLT-A-CRIB','ELEC-INS',           'E28011700000000000B01008', 142000,'2021-07-05','at_repair','Calibration lab, WO-5498','2026-10-28',false),
  ('AST-1009','Crimping Tool Set CT-9','Hand tool','PLT-A-CRIB','TOOL',          'E28011700000000000B01009',  19000,'2023-02-14','active',NULL,NULL,false),
  ('AST-1010','Cordless Drill Kit 18V','Power tool','PLT-A-CRIB','TOOL',         'E28011700000000000B01010',  16000,'2023-02-14','active',NULL,NULL,true),
  ('AST-1011','Hydraulic Pallet Truck 2T','Material handling','PLT-A-CRIB','MHE','E28011700000000000B01011',  64000,'2020-05-30','active',NULL,NULL,true),
  -- QA Lab
  ('AST-1012','Digital Oscilloscope 100MHz','Instrument','PLT-A-QA','ELEC-INS',  'E28011700000000000B01012', 310000,'2021-09-08','active',NULL,NULL,false),
  ('AST-1013','LCR Meter LCR-821','Instrument','PLT-A-QA','ELEC-INS',            'E28011700000000000B01013', 128000,'2022-04-22','active',NULL,NULL,false),
  ('AST-1014','Thermal Imaging Camera Ti-45','Instrument','PLT-A-QA','ELEC-INS', 'E28011700000000000B01014', 265000,'2023-01-10','on_loan','Lent to Plant B for a shutdown','2026-12-05',false),
  ('AST-1015','Environmental Chamber EC-60','Instrument','PLT-A-QA','LAB',       'E28011700000000000B01015', 890000,'2019-08-19','active',NULL,NULL,false),
  ('AST-1016','Vernier Caliper Set 0-300mm','Metrology','PLT-A-QA','LAB',         NULL,                        24000,'2023-06-01','active',NULL,NULL,false),
  ('AST-1017','Granite Surface Plate 600x400','Metrology','PLT-A-QA','LAB',      'E28011700000000000B01017',  72000,'2020-02-11','active',NULL,NULL,false),
  ('AST-1018','Power Quality Analyser PQ-3','Instrument','PLT-A-QA','ELEC-INS',  'E28011700000000000B01018', 420000,'2022-10-03','active',NULL,NULL,true),
  -- Engineering Bay. Laptops go home with people; that is not a discrepancy.
  ('AST-1019','Engineering Laptop EL-221','IT','OFC-B-ENG','COMP',               'E28011700000000000B01019',  98000,'2024-04-16','active',NULL,NULL,true),
  ('AST-1020','Engineering Laptop EL-222','IT','OFC-B-ENG','COMP',               'E28011700000000000B01020',  98000,'2024-04-16','active',NULL,NULL,true),
  ('AST-1021','Conference Projector CP-7','AV','OFC-B-ENG','COMP',               'E28011700000000000B01021',  62000,'2022-12-09','active',NULL,NULL,false),
  ('AST-1022','Plotter A1 DJ-T650','IT','OFC-B-ENG','COMP',                      'E28011700000000000B01022', 185000,'2023-05-25','active',NULL,NULL,false),
  ('AST-1023','Bench PSU 0-30V 5A','Instrument','OFC-B-ENG','ELEC-INS',          'E28011700000000000B01023',  31000,'2023-05-25','active',NULL,NULL,false),
  -- Spares Store. Racks and a cable drum were never tagged.
  ('AST-1024','MCB Spares Rack R-1','Spares','WH-C-SPR','FURN',                  'E28011700000000000B01024',  45000,'2020-01-20','active',NULL,NULL,false),
  ('AST-1025','Contactor Spares Rack R-2','Spares','WH-C-SPR','FURN',            'E28011700000000000B01025',  45000,'2020-01-20','active',NULL,NULL,false),
  ('AST-1026','Relay Module Carton RC-18','Spares','WH-C-SPR','FURN',             NULL,                        12000,'2023-11-02','active',NULL,NULL,false),
  ('AST-1027','Cable Drum 2.5sqmm 500m','Consumable','WH-C-SPR','FURN',           NULL,                        38000,'2024-02-08','active',NULL,NULL,false),
  ('AST-1028','Spare Motor 1.5kW','Spares','WH-C-SPR','PM-GEN',                  'E28011700000000000B01028',  76000,'2021-11-15','active',NULL,NULL,false)
  ) AS v(code,name,category,acode,ccode,epc,cost,in_use,status,note,due,mob)
  LEFT JOIN location    l ON l.site_id=s.id AND l.code=v.acode
  LEFT JOIN asset_class c ON c.site_id=s.id AND c.code=v.ccode
 WHERE s.code='PLT-A'
ON CONFLICT (site_id, code) DO NOTHING;

UPDATE asset a SET custodian_id = p.id, rev = 0
  FROM person p, (VALUES
    ('AST-1019','EMP-0301'), ('AST-1020','EMP-0301'),
    ('AST-1007','EMP-0871'), ('AST-1014','EMP-1188')
  ) AS v(acode,emp)
 WHERE a.code=v.acode AND p.emp_code=v.emp AND p.site_id=a.site_id;

COMMIT;

-- ---------------------------------------------------------------------
\echo ''
\echo '=== Accounts — PIN 1234 ==='
SELECT emp_code, name, role FROM person
 WHERE site_id=(SELECT id FROM site WHERE code='PLT-A')
 ORDER BY CASE role WHEN 'admin' THEN 1 WHEN 'approver' THEN 2
                    WHEN 'supervisor' THEN 3 WHEN 'operator' THEN 4 ELSE 5 END, emp_code;

\echo ''
\echo '=== Per area: what the register holds vs what a reader can see ==='
SELECT l.code, l.name,
       p.on_register AS "on register", p.untagged AS "no tag",
       p.mobile, p.offsite AS away, p.expected_by_reader AS "reader expects"
  FROM area_population p JOIN location l ON l.id=p.location_id
 WHERE l.site_id=(SELECT id FROM site WHERE code='PLT-A')
 ORDER BY l.code;

\echo ''
\echo '=== Net block as on 31 March 2026 ==='
SELECT c.code, count(*) AS n,
       to_char(sum(a.cost),'FM99,99,99,999') AS "gross block",
       to_char(sum(net_block(a.id,'2026-03-31')),'FM99,99,99,999') AS "net block"
  FROM asset a JOIN asset_class c ON c.id=a.class_id
 WHERE a.site_id=(SELECT id FROM site WHERE code='PLT-A')
   AND a.status NOT IN ('scrapped','written_off')
 GROUP BY c.code ORDER BY c.code;

\echo ''
\echo '=== Away from the plant ==='
SELECT code, name, status, status_note, due_back FROM asset
 WHERE status IN ('at_repair','on_loan','in_transit')
   AND site_id=(SELECT id FROM site WHERE code='PLT-A');

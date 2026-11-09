namespace TagTrail.Api;

/// <summary>
/// Every statement the API issues, in one place.
///
/// Deliberately raw SQL rather than EF Core. The schema is hand-written and
/// authoritative — it carries partial unique indexes, check constraints,
/// append-only triggers and a rev discipline that EF's model builder cannot
/// express and its migrations would fight. A generated migration diffing
/// against this schema would want to "fix" the very things that make it safe.
///
/// Keeping the SQL here also means it can be lifted out and run against a
/// real database on its own, which is how these were checked.
/// </summary>
public static class Sql
{
    // ---------------------------------------------------------------
    // Sign-in chooser
    //
    // The console needs to offer a site and a list of names before anyone has
    // signed in, exactly as the handheld does — nobody is going to type a UUID
    // on a shop floor. Names and roles only; no PIN material leaves the
    // database, and the PIN is still what actually authenticates.
    // ---------------------------------------------------------------

    public const string ListSites = @"
        SELECT id, code, name FROM tagtrail.site ORDER BY code;";

    public const string ListPeopleForSignIn = @"
        SELECT p.id, p.emp_code, p.name, p.role::text AS role, p.team_id,
               (p.pin_hash IS NOT NULL) AS has_pin,
               t.name AS team_name
          FROM tagtrail.person p
          LEFT JOIN tagtrail.team t ON t.id = p.team_id
         WHERE p.site_id = @siteId AND p.active
         ORDER BY CASE p.role
                    WHEN 'admin' THEN 1 WHEN 'approver' THEN 2
                    WHEN 'supervisor' THEN 3 WHEN 'operator' THEN 4 ELSE 5 END,
                  p.name;";

    /// Per area: what the register holds against what a reader can even see.
    /// The gap between the two is the number a coverage percentage has to
    /// disclose rather than quietly exclude.
    public const string AreaPopulations = @"
        SELECT l.code, l.name,
               p.on_register, p.untagged, p.mobile, p.offsite, p.retired,
               p.expected_by_reader
          FROM tagtrail.area_population p
          JOIN tagtrail.location l ON l.id = p.location_id
         WHERE l.site_id = @siteId
         ORDER BY l.code;";

    // ---------------------------------------------------------------
    // Identity
    // ---------------------------------------------------------------

    /// Sign-in. The PIN is compared inside the database by verify_pin, so the
    /// hash never crosses the wire and the API never holds it. A person with
    /// no PIN is refused outright — the browser build let them in with no
    /// credential at all, which undercut every "who did this" record.
    public const string SignIn = @"
        SELECT p.id, p.name, p.emp_code, p.role, p.team_id, p.site_id,
               (p.pin_hash IS NOT NULL)        AS has_pin,
               tagtrail.verify_pin(p.id, @pin) AS pin_ok
          FROM tagtrail.person p
         WHERE p.site_id = @siteId AND p.emp_code = @empCode AND p.active;";

    public const string LogAccess = @"
        INSERT INTO tagtrail.access_log (site_id, actor_id, actor_name, event, detail, device, ip)
        VALUES (@siteId, @actorId, @actorName, @event, @detail, @device, @ip::inet);";

    public const string CanSign = "SELECT tagtrail.can_sign(@personId);";

    // ---------------------------------------------------------------
    // Register
    // ---------------------------------------------------------------

    /// Paged, searchable, and valued as at a date rather than at whatever the
    /// global setting happened to be when the row was last written.
    public const string SearchAssets = @"
        SELECT a.id, a.code, a.name, a.category, a.epc, a.status, a.due_back,
               a.mobile, a.cost, a.in_use_date, a.rev,
               l.code AS home_code, l.name AS home_name,
               c.code AS class_code,
               tagtrail.net_block(a.id, @asOn)      AS net_block,
               tagtrail.accumulated_dep(a.id, @asOn) AS accum_dep
          FROM tagtrail.asset a
          LEFT JOIN tagtrail.location    l ON l.id = a.home_id
          LEFT JOIN tagtrail.asset_class c ON c.id = a.class_id
         WHERE a.site_id = @siteId
           AND (@q = '' OR a.code ILIKE '%' || @q || '%' OR a.name ILIKE '%' || @q || '%')
           AND (@includeRetired OR a.status NOT IN ('scrapped','written_off'))
         ORDER BY a.code
         LIMIT @limit OFFSET @offset;";

    public const string CountAssets = @"
        SELECT count(*) FROM tagtrail.asset a
         WHERE a.site_id = @siteId
           AND (@q = '' OR a.code ILIKE '%' || @q || '%' OR a.name ILIKE '%' || @q || '%')
           AND (@includeRetired OR a.status NOT IN ('scrapped','written_off'));";

    public const string GetAsset = @"
        SELECT a.*, tagtrail.net_block(a.id, @asOn) AS net_block
          FROM tagtrail.asset a WHERE a.id = @id AND a.site_id = @siteId;";

    /// The caller sends back the rev it read. The bump_rev trigger raises
    /// 40001 if the row has moved on, which the API turns into 409 Conflict
    /// rather than silently discarding a colleague's edit.
    public const string UpdateAsset = @"
        UPDATE tagtrail.asset
           SET code        = @code,
               name        = @name,
               category    = @category,
               home_id     = @homeId,
               class_id    = @classId,
               cost        = @cost,
               in_use_date = @inUseDate,
               mobile      = @mobile,
               custodian_id= @custodianId,
               rev         = @rev
         WHERE id = @id AND site_id = @siteId
        RETURNING rev;";

    /// Status and due-back move together: the check constraint refuses a
    /// return date on an asset that is not away, so they cannot drift apart.
    public const string SetAssetStatus = @"
        UPDATE tagtrail.asset
           SET status      = @status::tagtrail.asset_status,
               status_note = @note,
               status_at   = now(),
               due_back    = CASE WHEN @status IN ('at_repair','on_loan','in_transit')
                                  THEN @dueBack::date ELSE NULL END,
               rev         = @rev
         WHERE id = @id AND site_id = @siteId
        RETURNING rev, status, due_back;";

    // ---------------------------------------------------------------
    // Change log
    //
    // Written by the API because only the API knows the human-readable label
    // and which fields a caller actually changed. Append-only in the
    // database, so a bad write here cannot be tidied up afterwards — which is
    // the point.
    // ---------------------------------------------------------------

    public const string WriteChange = @"
        INSERT INTO tagtrail.change_log
            (site_id, actor_id, actor_name, actor_role, entity, entity_id,
             label, action, field, old_value, new_value)
        VALUES
            (@siteId, @actorId, @actorName, @actorRole::tagtrail.user_role, @entity, @entityId,
             @label, @action, @field, @oldValue, @newValue);";

    /// The optional filters are cast explicitly. Postgres cannot infer the
    /// type of a parameter that only ever appears beside IS NULL, and Npgsql
    /// needs the same hint to bind a null without being told the type.
    public const string ReadChangeLog = @"
        SELECT at, actor_name, actor_role, entity, entity_id, label,
               action, field, old_value, new_value
          FROM tagtrail.change_log
         WHERE site_id = @siteId
           AND (@entity::text IS NULL OR entity = @entity::text)
           AND (@actorId::uuid IS NULL OR actor_id = @actorId::uuid)
           AND at >= @from AND at < @to
         ORDER BY at DESC
         LIMIT @limit OFFSET @offset;";

    // ---------------------------------------------------------------
    // Audits
    // ---------------------------------------------------------------

    /// next_round_ref takes the number from a counter, under the insert's own
    /// lock. Counting existing rows and adding one — what the browser build
    /// did — gave two supervisors the same reference in the same month.
    public const string OpenRound = @"
        INSERT INTO tagtrail.audit_round (site_id, ref, title, reason, opened_by)
        VALUES (@siteId, tagtrail.next_round_ref(@siteId), @title, @reason, @openedBy)
        RETURNING id, ref, opened_at;";

    public const string AddScope = @"
        INSERT INTO tagtrail.round_scope (round_id, location_id)
        SELECT @roundId, unnest(@locationIds::uuid[])
        ON CONFLICT DO NOTHING;";

    public const string SkipArea = @"
        INSERT INTO tagtrail.round_skip (round_id, location_id, reason, skipped_by)
        VALUES (@roundId, @locationId, @reason, @by)
        ON CONFLICT (round_id, location_id)
        DO UPDATE SET reason = EXCLUDED.reason,
                      skipped_by = EXCLUDED.skipped_by,
                      skipped_at = now();";

    /// An audit may only close when every area in scope has been swept or
    /// skipped with a reason. Checked here and again by the caller's own
    /// guard, because an audit that closes with an area quietly not done is
    /// the finding the whole exercise exists to avoid.
    public const string RoundOutstanding = @"
        SELECT count(*)
          FROM tagtrail.round_scope rs
         WHERE rs.round_id = @roundId
           AND NOT EXISTS (SELECT 1 FROM tagtrail.sweep s
                            WHERE s.round_id = rs.round_id
                              AND s.location_id = rs.location_id
                              AND s.committed)
           AND NOT EXISTS (SELECT 1 FROM tagtrail.round_skip k
                            WHERE k.round_id = rs.round_id
                              AND k.location_id = rs.location_id);";

    public const string CloseRound = @"
        UPDATE tagtrail.audit_round
           SET status = 'closed', closed_by = @by, closed_at = now(), rev = @rev
         WHERE id = @roundId AND site_id = @siteId AND status = 'open'
        RETURNING rev;";

    /// The check constraint refuses a signer who opened it, so the API does
    /// not need to re-check; it only has to report the refusal properly.
    public const string SignOffRound = @"
        UPDATE tagtrail.audit_round
           SET signed_off_by = @by, signed_off_at = now(), rev = @rev
         WHERE id = @roundId AND site_id = @siteId AND status = 'closed'
        RETURNING rev;";

    /// Areas, for choosing a scope and for the worklist.
    public const string ListLocations = @"
        SELECT l.id, l.code, l.name, t.name AS team_name,
               p.on_register, p.expected_by_reader
          FROM tagtrail.location l
          LEFT JOIN tagtrail.team t ON t.id = l.team_id
          LEFT JOIN tagtrail.area_population p ON p.location_id = l.id
         WHERE l.site_id = @siteId
         ORDER BY l.code;";

    /// Every audit, newest first, with enough progress to show a list without
    /// a second round trip per row.
    public const string ListRounds = @"
        SELECT r.id, r.ref, r.title, r.reason, r.status::text AS status,
               r.opened_at, r.closed_at, r.signed_off_at, r.rev,
               po.name AS opened_by_name,
               so.name AS signed_off_by_name,
               (SELECT count(*) FROM tagtrail.round_scope sc WHERE sc.round_id = r.id) AS areas,
               (SELECT count(*) FROM tagtrail.sweep s
                 WHERE s.round_id = r.id AND s.committed)                              AS areas_done,
               (SELECT count(*) FROM tagtrail.round_skip k WHERE k.round_id = r.id)    AS areas_skipped
          FROM tagtrail.audit_round r
          LEFT JOIN tagtrail.person po ON po.id = r.opened_by
          LEFT JOIN tagtrail.person so ON so.id = r.signed_off_by
         WHERE r.site_id = @siteId
         ORDER BY r.opened_at DESC;";

    /// The worklist: every area in scope and where it stands. This is what an
    /// operator actually works from, so it has to say plainly which areas are
    /// still outstanding — an audit that closes with an area quietly not done
    /// is the finding the whole exercise exists to avoid.
    public const string RoundWorklist = @"
        SELECT l.id, l.code, l.name,
               p.on_register, p.expected_by_reader,
               s.id            AS sweep_id,
               s.committed,
               s.ended_at,
               op.name         AS operator_name,
               (SELECT count(*) FROM tagtrail.sweep_read r WHERE r.sweep_id = s.id) AS reads,
               k.reason        AS skip_reason,
               sk.name         AS skipped_by_name,
               CASE WHEN s.id IS NOT NULL AND s.committed THEN 'done'
                    WHEN s.id IS NOT NULL                 THEN 'scanning'
                    WHEN k.location_id IS NOT NULL        THEN 'skipped'
                    ELSE 'todo' END AS state
          FROM tagtrail.round_scope rs
          JOIN tagtrail.location l ON l.id = rs.location_id
          LEFT JOIN tagtrail.area_population p ON p.location_id = l.id
          LEFT JOIN tagtrail.sweep s ON s.round_id = rs.round_id AND s.location_id = l.id
          LEFT JOIN tagtrail.person op ON op.id = s.operator_id
          LEFT JOIN tagtrail.round_skip k ON k.round_id = rs.round_id AND k.location_id = l.id
          LEFT JOIN tagtrail.person sk ON sk.id = k.skipped_by
         WHERE rs.round_id = @roundId
         ORDER BY l.code;";

    /// The tags a reader would physically encounter in an area. Used only by
    /// the demonstration button that stands in for a handheld — a real sweep
    /// gets its EPCs from the reader, and must never get them from here, or
    /// it would be reading the register back to itself and always agree.
    public const string TagsInArea = @"
        SELECT a.epc, a.code, a.mobile
          FROM tagtrail.asset a
         WHERE a.home_id = @locationId
           AND a.epc IS NOT NULL
           AND a.status NOT IN ('scrapped','written_off')
         ORDER BY a.code;";

    /// What the sweep would conclude, without committing anything. The
    /// operator has to see the exceptions while still standing in the area —
    /// finding out afterwards means walking back.
    public const string SweepPreview = @"
        WITH scanned AS (
          SELECT r.epc, r.rssi_max, r.read_count, c.result, c.asset_id, c.home_id, c.detail
            FROM tagtrail.sweep_read r
            CROSS JOIN LATERAL tagtrail.classify_read(@siteId, @locationId, r.epc) c
           WHERE r.sweep_id = @sweepId AND r.rssi_max >= @floor
        ), unread AS (
          SELECT a.id AS asset_id, a.code, a.name, a.epc, a.mobile, a.status::text AS status,
                 tagtrail.net_block(a.id, @asOn) AS nbv
            FROM tagtrail.asset a
           WHERE a.home_id = @locationId
             AND a.epc IS NOT NULL
             AND a.status NOT IN ('scrapped','written_off')
             AND NOT EXISTS (SELECT 1 FROM tagtrail.sweep_read r
                              WHERE r.sweep_id = @sweepId AND r.epc = a.epc
                                AND r.rssi_max >= @floor)
        )
        SELECT s.result, s.epc, s.rssi_max, s.read_count, s.detail,
               a.code AS asset_code, a.name AS asset_name,
               hl.code AS home_code,
               NULL::numeric AS nbv
          FROM scanned s
          LEFT JOIN tagtrail.asset a ON a.id = s.asset_id
          LEFT JOIN tagtrail.location hl ON hl.id = s.home_id
        UNION ALL
        SELECT (CASE WHEN u.status IN ('at_repair','on_loan','in_transit') THEN 'offsite'
                     WHEN u.mobile THEN 'away'
                     ELSE 'missing' END)::tagtrail.finding,
               u.epc, NULL::smallint, 0,
               (CASE WHEN u.status IN ('at_repair','on_loan','in_transit')
                     THEN 'recorded as away from the plant' END)::text,
               u.code, u.name, NULL::citext, u.nbv
          FROM unread u;";

    // ---------------------------------------------------------------
    // Sweeps
    // ---------------------------------------------------------------

    /// The partial unique index allows exactly one uncommitted sweep per area
    /// per audit, so four handhelds cannot each believe they own the bay.
    /// A second device gets 23505 and is told who holds it.
    public const string StartSweep = @"
        INSERT INTO tagtrail.sweep
            (site_id, round_id, location_id, operator_id, started_at,
             rssi_floor, tx_power, expected_n, register_n)
        SELECT @siteId, @roundId, @locationId, @operatorId, now(),
               s.rssi_floor, s.tx_power,
               p.expected_by_reader, p.on_register
          FROM tagtrail.site s
          JOIN tagtrail.area_population p ON p.location_id = @locationId
         WHERE s.id = @siteId
        RETURNING id, started_at, rssi_floor, expected_n, register_n;";

    public const string LiveSweepForArea = @"
        SELECT s.id, s.started_at, s.operator_id, p.name AS operator_name,
               (SELECT count(*) FROM tagtrail.sweep_read r WHERE r.sweep_id = s.id) AS reads
          FROM tagtrail.sweep s
          JOIN tagtrail.person p ON p.id = s.operator_id
         WHERE s.round_id = @roundId AND s.location_id = @locationId AND NOT s.committed;";

    /// Any live sweep this person could pick up. A dead battery or a shift
    /// change leaves one of these, and the operator is offered it rather than
    /// walking the area again.
    public const string LiveSweeps = @"
        SELECT s.id, s.location_id, l.code AS location_code, l.name AS location_name,
               s.round_id, r.ref AS round_ref, r.title AS round_title,
               s.started_at, s.operator_id, p.name AS operator_name,
               (SELECT count(*) FROM tagtrail.sweep_read sr WHERE sr.sweep_id = s.id) AS reads
          FROM tagtrail.sweep s
          JOIN tagtrail.location l ON l.id = s.location_id
          JOIN tagtrail.person   p ON p.id = s.operator_id
          LEFT JOIN tagtrail.audit_round r ON r.id = s.round_id
         WHERE s.site_id = @siteId AND NOT s.committed
         ORDER BY s.started_at DESC;";

    /// The hot path. A handheld streams tens of reads a second, so they
    /// arrive as a batch and land in one statement. The best RSSI is kept for
    /// compatibility and the median is accumulated separately, because
    /// applying the floor to the maximum is how one lucky reflection off a
    /// neighbour's tag gets promoted to a finding.
    public const string UpsertReads = @"
        INSERT INTO tagtrail.sweep_read (sweep_id, epc, rssi_max, rssi_med, read_count, first_at, last_at)
        SELECT @sweepId, r.epc, r.rssi, r.rssi, 1, now(), now()
          FROM unnest(@epcs::citext[], @rssis::smallint[]) AS r(epc, rssi)
        ON CONFLICT (sweep_id, epc) DO UPDATE
           SET rssi_max   = GREATEST(tagtrail.sweep_read.rssi_max, EXCLUDED.rssi_max),
               rssi_med   = (tagtrail.sweep_read.rssi_med * tagtrail.sweep_read.read_count
                             + EXCLUDED.rssi_max) / (tagtrail.sweep_read.read_count + 1),
               read_count = tagtrail.sweep_read.read_count + 1,
               last_at    = now();";

    public const string SweepReads = @"
        SELECT epc, rssi_max, rssi_med, read_count, first_at, last_at
          FROM tagtrail.sweep_read WHERE sweep_id = @sweepId ORDER BY last_at DESC;";

    /// Recorded when a different person picks up a live sweep. The report has
    /// to name everyone whose reads are in the count, not just whoever
    /// pressed save — an auditor asking "who counted this area" must not get
    /// one name when two people walked it.
    public const string RecordHandover = @"
        WITH h AS (
          INSERT INTO tagtrail.sweep_handover (sweep_id, from_id, to_id, reads_at_handover)
          SELECT @sweepId, s.operator_id, @toId,
                 (SELECT count(*) FROM tagtrail.sweep_read r WHERE r.sweep_id = s.id)
            FROM tagtrail.sweep s
           WHERE s.id = @sweepId AND s.operator_id <> @toId
          RETURNING sweep_id
        )
        UPDATE tagtrail.sweep SET operator_id = @toId, rev = 0
         WHERE id = (SELECT sweep_id FROM h)
        RETURNING operator_id;";

    /// What a sweep concluded, per asset or stray tag. classify_read decides,
    /// so the handheld and the console cannot disagree about what a reading
    /// means.
    public const string ClassifyReads = @"
        SELECT r.epc, r.rssi_max, r.rssi_med, r.read_count, c.*
          FROM tagtrail.sweep_read r
          CROSS JOIN LATERAL tagtrail.classify_read(@siteId, @locationId, r.epc) c
         WHERE r.sweep_id = @sweepId
           AND r.rssi_max >= @floor;";

    /// Assets homed here that no reading accounted for. Split exactly as the
    /// floor needs: away from the plant, moves by design, or genuinely not
    /// found — the last being the only one that is a discrepancy.
    public const string UnaccountedAssets = @"
        SELECT a.id, a.code, a.name, a.epc, a.mobile, a.status,
               tagtrail.net_block(a.id, @asOn) AS nbv
          FROM tagtrail.asset a
         WHERE a.home_id = @locationId
           AND a.epc IS NOT NULL
           AND a.status NOT IN ('scrapped','written_off')
           AND NOT EXISTS (
                 SELECT 1 FROM tagtrail.sweep_read r
                  WHERE r.sweep_id = @sweepId AND r.epc = a.epc
                    AND r.rssi_max >= @floor);";

    public const string InsertSweepRow = @"
        INSERT INTO tagtrail.sweep_row
            (sweep_id, result, asset_id, epc, home_id, rssi, nbv, note, seen_by)
        VALUES
            (@sweepId, @result::tagtrail.finding, @assetId, @epc, @homeId,
             @rssi, @nbv, @note, @seenBy);";

    public const string CommitSweep = @"
        UPDATE tagtrail.sweep
           SET committed = true, ended_at = now(),
               value_checked = @valueChecked, value_missing = @valueMissing,
               valued_as_on  = @asOn, rev = @rev
         WHERE id = @sweepId AND NOT committed
        RETURNING rev;";

    /// Last-seen, written only for assets actually read. The browser build
    /// updated this from a possibly stale copy of the asset, clobbering a
    /// cost edit another device had made in the meantime; rev = 0 here is
    /// deliberate and narrow — it touches only these two columns.
    public const string TouchLastSeen = @"
        UPDATE tagtrail.asset
           SET last_seen_id = @locationId, last_seen_at = now(), rev = 0
         WHERE id = ANY(@assetIds::uuid[]);";

    // ---------------------------------------------------------------
    // Jobs
    // ---------------------------------------------------------------

    /// One open job per asset per type, enforced by a partial unique index.
    /// The browser build deduplicated in JavaScript against one device's own
    /// copy, so four handhelds finishing four areas each raised their own
    /// Return job for the same wandering trolley. ON CONFLICT bumps the
    /// priority of the existing one instead.
    public const string RaiseTask = @"
        INSERT INTO tagtrail.task
            (site_id, type, asset_id, epc, expected_id, found_id,
             round_id, sweep_id, team_id, due_at)
        VALUES
            (@siteId, @type::tagtrail.task_type, @assetId, @epc, @expectedId, @foundId,
             @roundId, @sweepId, @teamId,
             now() + make_interval(days => @slaDays))
        ON CONFLICT (asset_id, type) WHERE status <> 'closed' AND asset_id IS NOT NULL
        DO UPDATE SET priority = LEAST(3, tagtrail.task.priority + 1),
                      rev = 0
        RETURNING id, (xmax = 0) AS was_new;";

    public const string AddTaskHistory = @"
        INSERT INTO tagtrail.task_history (task_id, actor_id, actor_name, what)
        VALUES (@taskId, @actorId, @actorName, @what);";

    // ---------------------------------------------------------------
    // Tag replacement
    // ---------------------------------------------------------------

    /// The whole act in one transaction: verify the signature, move the tag,
    /// record the replacement. If any part fails nothing moves — a tag that
    /// changed without a signed record beside it is the thing this exists to
    /// prevent.
    public const string ApplyRetag = @"
        WITH signed AS (
          SELECT tagtrail.verify_pin(@byId, @pin) AS ok
        ), moved AS (
          UPDATE tagtrail.asset
             SET epc = @newEpc, tagged_at = now(), tagged_by = @byId,
                 retag_count = retag_count + 1, rev = @rev
           WHERE id = @assetId AND site_id = @siteId
             AND epc = @oldEpc
             AND (SELECT ok FROM signed)
          RETURNING id, code, name, home_id
        )
        INSERT INTO tagtrail.retag
            (site_id, batch_ref, asset_id, asset_code, asset_name,
             old_epc, new_epc, reason, remarks, by_id, by_name, by_role, signed)
        SELECT @siteId, @batchRef, m.id, m.code, m.name,
               @oldEpc, @newEpc, @reason::tagtrail.retag_reason, @remarks,
               p.id, p.name, p.role, true
          FROM moved m, tagtrail.person p
         WHERE p.id = @byId
        RETURNING id;";

    /// The correction made during a verification pass, where no PIN is
    /// entered. Recorded as unsigned rather than passed off as signed; the
    /// report shows it in red.
    public const string RecordUnsignedRetag = @"
        INSERT INTO tagtrail.retag
            (site_id, asset_id, asset_code, asset_name, old_epc, new_epc,
             reason, remarks, by_id, by_name, by_role, signed)
        SELECT @siteId, a.id, a.code, a.name, @oldEpc, @newEpc,
               'wrong', @remarks, p.id, p.name, p.role, false
          FROM tagtrail.asset a, tagtrail.person p
         WHERE a.id = @assetId AND p.id = @byId
        RETURNING id;";

    public const string RetagsForReport = @"
        SELECT r.at, r.by_name, p.emp_code AS by_code, r.asset_code, r.asset_name,
               r.old_epc, r.new_epc, r.reason, r.remarks, r.signed, r.batch_ref
          FROM tagtrail.retag r
          LEFT JOIN tagtrail.person p ON p.id = r.by_id
         WHERE r.site_id = @siteId
         ORDER BY r.at DESC LIMIT @limit OFFSET @offset;";

    // ---------------------------------------------------------------
    // Reports
    // ---------------------------------------------------------------

    /// The figures a physical-verification report must state. Both coverages
    /// are returned: against what the reader could see, and against the whole
    /// register. Reporting only the first is how "248 of 248 — 100%" ends up
    /// on a certificate for a population silently narrowed by every untagged
    /// and mobile asset.
    public const string RoundReport = @"
        WITH scope AS (
          SELECT rs.location_id FROM tagtrail.round_scope rs WHERE rs.round_id = @roundId
        ), pop AS (
          SELECT COALESCE(sum(p.on_register),0)        AS on_register,
                 COALESCE(sum(p.untagged),0)           AS untagged,
                 COALESCE(sum(p.mobile),0)             AS mobile,
                 COALESCE(sum(p.offsite),0)            AS offsite,
                 COALESCE(sum(p.expected_by_reader),0) AS expected_by_reader
            FROM tagtrail.area_population p
            JOIN scope ON scope.location_id = p.location_id
        ), swept AS (
          SELECT count(*) FILTER (WHERE s.committed)                      AS areas_done,
                 COALESCE(sum(s.expected_n) FILTER (WHERE s.committed),0) AS expected_n,
                 COALESCE(sum(s.value_checked),0)                         AS value_checked,
                 COALESCE(sum(s.value_missing),0)                         AS value_missing,
                 min(s.ended_at)                                          AS first_count,
                 max(s.ended_at)                                          AS last_count
            FROM tagtrail.sweep s JOIN scope ON scope.location_id = s.location_id
           WHERE s.round_id = @roundId
        ), rows AS (
          SELECT count(*) FILTER (WHERE sr.result = 'inplace')   AS inplace,
                 count(*) FILTER (WHERE sr.result = 'eyeballed') AS eyeballed,
                 count(*) FILTER (WHERE sr.result = 'missing')   AS missing,
                 count(*) FILTER (WHERE sr.result = 'misplaced') AS misplaced,
                 count(*) FILTER (WHERE sr.result = 'unknown')   AS unknown,
                 count(*) FILTER (WHERE sr.result = 'offsite')   AS offsite_read,
                 count(*) FILTER (WHERE sr.result = 'retired')   AS retired
            FROM tagtrail.sweep_row sr
            JOIN tagtrail.sweep s ON s.id = sr.sweep_id AND s.committed
           WHERE s.round_id = @roundId
        )
        SELECT r.*, pop.*, swept.*, rows.*,
               (SELECT count(*) FROM scope)                           AS areas_in_scope,
               (SELECT count(*) FROM tagtrail.round_skip k
                 WHERE k.round_id = @roundId)                         AS areas_skipped,
               (rows.inplace + rows.eyeballed)                        AS verified_n,
               CASE WHEN pop.on_register > 0
                    THEN round((rows.inplace + rows.eyeballed)::numeric * 100 / pop.on_register, 1)
               END                                                    AS register_coverage_pct,
               CASE WHEN swept.expected_n > 0
                    THEN round(rows.inplace::numeric * 100 / swept.expected_n, 1)
               END                                                    AS reader_coverage_pct
          FROM tagtrail.audit_round r, pop, swept, rows
         WHERE r.id = @roundId;";

    /// Class-wise gross block, accumulated depreciation and net block as at a
    /// date, with the unaccounted figure CARO 3(i)(b) asks about computed from
    /// the sweeps rather than from a frozen column.
    public const string FixedAssetRegister = @"
        SELECT COALESCE(c.code,'UNCLASSIFIED')    AS class_code,
               COALESCE(c.name,'Unclassified')    AS class_name,
               c.useful_life, c.method,
               count(*)                                            AS n,
               sum(a.cost)                                         AS gross_block,
               sum(tagtrail.accumulated_dep(a.id, @asOn))          AS accum_dep,
               sum(tagtrail.net_block(a.id, @asOn))                AS net_block,
               sum(tagtrail.net_block(a.id, @asOn))
                 FILTER (WHERE EXISTS (
                    SELECT 1 FROM tagtrail.sweep_row sr
                      JOIN tagtrail.sweep s ON s.id = sr.sweep_id AND s.committed
                     WHERE sr.asset_id = a.id AND sr.result = 'missing'
                       AND s.ended_at = (SELECT max(s2.ended_at)
                                           FROM tagtrail.sweep s2
                                          WHERE s2.location_id = a.home_id AND s2.committed
                                            AND s2.ended_at <= @asOn + 1)))  AS unaccounted_net_block
          FROM tagtrail.asset a
          LEFT JOIN tagtrail.asset_class c ON c.id = a.class_id
         WHERE a.site_id = @siteId
           AND a.status NOT IN ('scrapped','written_off')
           AND a.cost IS NOT NULL AND a.in_use_date IS NOT NULL
         GROUP BY c.code, c.name, c.useful_life, c.method
         ORDER BY net_block DESC NULLS LAST;";

    /// Cross-reads, so a commit can mark them instead of raising work. An
    /// asset confirmed in its own area and read faintly next door the same
    /// day is RF physics, not a movement.
    public const string CrossReads = @"
        SELECT * FROM tagtrail.cross_read_candidates
         WHERE round_id = @roundId
           AND areas_adjacent
           AND rssi_away < rssi_home;";

    public const string OverdueReturns =
        "SELECT * FROM tagtrail.overdue_returns WHERE site_id = @siteId ORDER BY days_overdue DESC;";
}

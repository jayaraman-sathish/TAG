using System.Data;
using Dapper;
using Npgsql;
using TagTrail.Api;

var builder = WebApplication.CreateBuilder(args);

var cs = builder.Configuration.GetConnectionString("TagTrail")
         ?? "Host=localhost;Port=5432;Database=tagtrail;Username=postgres";

// The enums in Models.cs mirror the database types as documentation, but they
// are deliberately NOT registered here. Every statement casts text explicitly
// (`@status::tagtrail.asset_status`), so nothing binds them — and registering a
// mapping whose labels did not match would throw at startup for no benefit.
var dataSource = new NpgsqlDataSourceBuilder(cs).Build();

// Must be registered before the first query. Without it, every endpoint that
// takes an "as on" date fails at parameter binding rather than in the
// database, so the error says nothing useful about what went wrong.
Dapper.SqlMapper.AddTypeHandler(new DateOnlyHandler());

builder.Services.AddSingleton(dataSource);
builder.Services.AddSingleton<Db>();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

// The console and the handheld are both browsers as far as this is concerned.
builder.Services.AddCors(o => o.AddDefaultPolicy(p => p
    .WithOrigins(builder.Configuration.GetSection("AllowedOrigins").Get<string[]>()
                 ?? ["http://localhost:5173", "http://localhost:8080"])
    .AllowAnyHeader().AllowAnyMethod().AllowCredentials()));

var app = builder.Build();

// ---------------------------------------------------------------------
// Schema catch-up
//
// The init scripts in db/ only run against an empty data volume, so a
// column added after the first start would never reach a database that is
// already running — and the only remedy would be destroying the volume and
// everything in it. These statements are idempotent and cost microseconds,
// so a schema change lands on a live database without anyone losing a
// register. 001_schema.sql stays authoritative; this only catches up.
// ---------------------------------------------------------------------
await using (var mig = await app.Services.GetRequiredService<Db>().OpenAsync())
{
    await mig.ExecuteAsync(
        "ALTER TABLE tagtrail.location ADD COLUMN IF NOT EXISTS area text;");

    // The seed sets these, but the seed only runs on a fresh volume. Guarded
    // to the five seeded codes and to rows where nobody has typed an area
    // yet, so it can never overwrite what someone entered on the screen.
    await mig.ExecuteAsync(@"
        UPDATE tagtrail.location l SET area = v.area
          FROM (VALUES ('PLT-A-ASSY','Plant A'), ('PLT-A-CRIB','Plant A'),
                       ('PLT-A-QA','Plant A'),   ('OFC-B-ENG','Office B'),
                       ('WH-C-SPR','Warehouse C')) AS v(code, area)
         WHERE l.code = v.code AND l.area IS NULL;");
}

app.UseCors();
// The console is served from wwwroot by this same service, which means it is
// same-origin: the cookie just works, and there is no CORS to configure for
// the common case. Nobody should need a terminal to use this.
app.UseDefaultFiles();
// The console is one big HTML file that changes on every build. Served with
// the default caching headers, a browser will happily keep showing yesterday's
// copy — which looks exactly like the new code failing, and wastes an hour
// proving it isn't. Tell the browser to re-check every time; it is one file on
// a local network, so there is nothing to gain by caching it.
app.UseStaticFiles(new StaticFileOptions
{
    OnPrepareResponse = ctx =>
    {
        ctx.Context.Response.Headers.CacheControl = "no-cache, no-store, must-revalidate";
        ctx.Context.Response.Headers.Pragma = "no-cache";
        ctx.Context.Response.Headers.Expires = "0";
    }
});
if (app.Environment.IsDevelopment()) { app.UseSwagger(); app.UseSwaggerUI(); }

// Every database refusal becomes the answer it deserves rather than a 500.
// See Db.Describe: these are guards firing correctly, not server faults.
app.Use(async (ctx, next) =>
{
    try { await next(); }
    catch (PostgresException e)
    {
        var (status, code, message) = Db.Describe(e);
        ctx.Response.StatusCode = status;
        await ctx.Response.WriteAsJsonAsync(new { error = code, message, constraint = e.ConstraintName });
    }
});

// ---------------------------------------------------------------------
// Sessions
//
// A cookie holding the person id, nothing else. For the POC that is enough;
// before a pilot it should be the plant's own SSO, which is why the identity
// is resolved in one place and never read from the request body.
// ---------------------------------------------------------------------

async Task<Caller?> CurrentAsync(HttpContext ctx, Db db)
{
    if (!ctx.Request.Cookies.TryGetValue("tt_person", out var raw) || !Guid.TryParse(raw, out var pid))
        return null;
    await using var c = await db.OpenAsync();
    return await c.QuerySingleOrDefaultAsync<Caller>(
        @"SELECT site_id AS SiteId, id AS PersonId, name AS Name,
                 emp_code AS EmpCode, role::text AS Role
            FROM tagtrail.person WHERE id = @pid AND active;", new { pid });
}

IResult Forbidden(string permission) =>
    Results.Json(new { error = "forbidden",
        message = $"Your role cannot do that ({permission})." }, statusCode: 403);

// ---------------------------------------------------------------------
// Sign-in chooser
//
// Open before sign-in on purpose: the console has to offer a site and a list
// of names, exactly as the handheld does. Nobody types a UUID on a shop
// floor. Names and roles only — the PIN is still what authenticates, and no
// PIN material is returned.
//
// Before this is on a plant network rather than a laptop, the people list
// should go behind the site's own sign-on. It is a staff directory.
// ---------------------------------------------------------------------

app.MapGet("/api/sites", async (Db db) =>
{
    await using var c = await db.OpenAsync();
    return Results.Ok(await c.QueryAsync(Sql.ListSites));
});

app.MapGet("/api/sites/{siteId:guid}/people", async (Guid siteId, Db db) =>
{
    await using var c = await db.OpenAsync();
    return Results.Ok(await c.QueryAsync(Sql.ListPeopleForSignIn, new { siteId }));
});

// ---------------------------------------------------------------------
// Sign in and out
// ---------------------------------------------------------------------

app.MapPost("/api/auth/signin", async (SignInRequest req, Db db, HttpContext ctx) =>
{
    await using var c = await db.OpenAsync();
    var row = await c.QuerySingleOrDefaultAsync(Sql.SignIn,
        new { siteId = req.SiteId, empCode = req.EmpCode, pin = req.Pin ?? "" });

    // A failed attempt is recorded. The browser build logged neither the
    // success nor the failure, so you could see what somebody changed but not
    // that they were ever in the system.
    async Task LogAsync(Guid? who, string name, string ev, string? detail) =>
        await c.ExecuteAsync(Sql.LogAccess, new {
            siteId = req.SiteId, actorId = who, actorName = name, @event = ev,
            detail, device = ctx.Request.Headers.UserAgent.ToString(),
            ip = ctx.Connection.RemoteIpAddress?.ToString()
        });

    if (row is null)
    {
        await LogAsync(null, req.EmpCode, "sign_in_failed", "no such active person");
        return Results.Json(new { error = "unknown_user", message = "No active user with that employee code." },
                            statusCode: 401);
    }

    // Anyone without a PIN could previously sign in with no credential at
    // all, which undercut every "who did this" record in the register.
    if (!(bool)row.has_pin)
    {
        await LogAsync((Guid)row.id, (string)row.name, "sign_in_failed", "no PIN set");
        return Results.Json(new { error = "no_pin",
            message = "That account has no PIN set. An administrator must set one before it can be used — "
                    + "the register has to be able to name who did each thing." }, statusCode: 403);
    }

    if (!(bool)row.pin_ok)
    {
        await LogAsync((Guid)row.id, (string)row.name, "sign_in_failed", "wrong PIN");
        return Results.Json(new { error = "bad_pin", message = "That PIN does not match." }, statusCode: 401);
    }

    await LogAsync((Guid)row.id, (string)row.name, "sign_in", null);
    ctx.Response.Cookies.Append("tt_person", ((Guid)row.id).ToString(), new CookieOptions
    {
        HttpOnly = true, SameSite = SameSiteMode.Lax, Path = "/",
        Expires = DateTimeOffset.UtcNow.AddHours(12)   // a shift, not a fortnight
    });
    return Results.Ok(new { id = row.id, name = row.name, empCode = row.emp_code, role = row.role });
});

app.MapPost("/api/auth/signout", async (Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is not null)
    {
        await using var c = await db.OpenAsync();
        await c.ExecuteAsync(Sql.LogAccess, new {
            siteId = me.SiteId, actorId = me.PersonId, actorName = me.Name,
            @event = "sign_out", detail = (string?)null,
            device = ctx.Request.Headers.UserAgent.ToString(),
            ip = ctx.Connection.RemoteIpAddress?.ToString() });
    }
    ctx.Response.Cookies.Delete("tt_person");
    return Results.Ok();
});

// ---------------------------------------------------------------------
// Register
// ---------------------------------------------------------------------

app.MapGet("/api/assets", async (Db db, HttpContext ctx,
    string? q, bool includeRetired = false, DateOnly? asOn = null, int page = 1, int size = 50) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    await using var c = await db.OpenAsync();
    var args = new {
        siteId = me.SiteId, q = q ?? "", includeRetired,
        asOn = asOn ?? DateOnly.FromDateTime(DateTime.Today),
        limit = Math.Clamp(size, 1, 250), offset = Math.Max(0, page - 1) * Math.Clamp(size, 1, 250)
    };
    var rows  = await c.QueryAsync(Sql.SearchAssets, args);
    var total = await c.ExecuteScalarAsync<long>(Sql.CountAssets, args);
    return Results.Ok(new { total, page, size = args.limit, rows });
});

app.MapPut("/api/assets/{id:guid}", async (Guid id, AssetUpdate body, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    if (!me.Can("register.edit")) return Forbidden("register.edit");

    await using var c = await db.OpenAsync();
    await using var tx = await c.BeginTransactionAsync();

    var before = await c.QuerySingleOrDefaultAsync(Sql.GetAsset,
        new { id, siteId = me.SiteId, asOn = DateOnly.FromDateTime(DateTime.Today) }, tx);
    if (before is null) return Results.NotFound();

    var rev = await c.ExecuteScalarAsync<int>(Sql.UpdateAsset, new {
        id, siteId = me.SiteId, body.Code, body.Name, body.Category,
        homeId = body.HomeId, classId = body.ClassId, body.Cost,
        inUseDate = body.InUseDate, body.Mobile, custodianId = body.CustodianId,
        rev = body.Rev }, tx);

    // The log records fields, not whole rows: "cost 13,000 -> 450,000" is what
    // an auditor asks for, and a row dump is not an answer.
    //
    // Cast to the dictionary interface Dapper's row already implements. Passing
    // `before` as dynamic would make the whole call dynamically bound, and a
    // dynamic result cannot be deconstructed.
    var beforeRow = (IDictionary<string, object>)before;
    foreach (var (field, was, became) in Diff.Fields(beforeRow, body))
        await c.ExecuteAsync(Sql.WriteChange, new {
            siteId = me.SiteId, actorId = me.PersonId, actorName = me.Name, actorRole = me.Role,
            entity = "asset", entityId = id, label = $"{body.Code} — {body.Name}",
            action = "changed", field, oldValue = was, newValue = became }, tx);

    await tx.CommitAsync();
    return Results.Ok(new { id, rev });
});

app.MapPost("/api/assets/{id:guid}/status", async (Guid id, StatusChange body, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    if (!me.Can("register.edit")) return Forbidden("register.edit");

    // Taking an asset off the books is a different act from sending it out for
    // repair, and only finance may do the first.
    if (body.Status is "scrapped" or "written_off" && !me.Can("writeoff.approve"))
        return Forbidden("writeoff.approve");

    await using var c = await db.OpenAsync();
    await using var tx = await c.BeginTransactionAsync();
    var row = await c.QuerySingleAsync(Sql.SetAssetStatus, new {
        id, siteId = me.SiteId, status = body.Status, note = body.Note,
        dueBack = body.DueBack, rev = body.Rev }, tx);
    await c.ExecuteAsync(Sql.WriteChange, new {
        siteId = me.SiteId, actorId = me.PersonId, actorName = me.Name, actorRole = me.Role,
        entity = "asset", entityId = id, label = body.Label, action = "changed",
        field = "status", oldValue = body.PreviousStatus, newValue = body.Status }, tx);
    await tx.CommitAsync();
    return Results.Ok(row);
});

// ---------------------------------------------------------------------
// Audits
// ---------------------------------------------------------------------

app.MapPost("/api/rounds", async (OpenRound body, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    if (!me.Can("audit")) return Forbidden("audit");
    if (body.LocationIds.Length == 0)
        return Results.UnprocessableEntity(new { error = "empty_scope",
            message = "An audit with no areas in scope would close as complete having verified nothing." });

    await using var c = await db.OpenAsync();
    await using var tx = await c.BeginTransactionAsync();
    var r = await c.QuerySingleAsync(Sql.OpenRound, new {
        siteId = me.SiteId, body.Title, body.Reason, openedBy = me.PersonId }, tx);
    await c.ExecuteAsync(Sql.AddScope, new { roundId = (Guid)r.id, locationIds = body.LocationIds }, tx);
    await c.ExecuteAsync(Sql.WriteChange, new {
        siteId = me.SiteId, actorId = me.PersonId, actorName = me.Name, actorRole = me.Role,
        entity = "audit_round", entityId = (Guid)r.id, label = body.Title,
        action = "created", field = "scope",
        oldValue = (string?)null, newValue = $"{body.LocationIds.Length} areas" }, tx);
    await tx.CommitAsync();
    var row = (IDictionary<string, object>)r;
    return Results.Ok(new {
        id        = row["id"],
        reference = row["ref"],      // "ref" is a C# keyword; read it by key
        openedAt  = row["opened_at"] });
});

app.MapPost("/api/rounds/{id:guid}/close", async (Guid id, int rev, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    if (!me.Can("audit")) return Forbidden("audit");

    await using var c = await db.OpenAsync();
    // An area quietly never done is the finding the whole exercise exists to
    // avoid, so this is checked rather than trusted to the UI's disabled button.
    var left = await c.ExecuteScalarAsync<long>(Sql.RoundOutstanding, new { roundId = id });
    if (left > 0)
        return Results.UnprocessableEntity(new { error = "areas_outstanding",
            message = $"{left} area(s) in scope have been neither scanned nor skipped with a reason. "
                    + "Closing now would report the audit as complete with those areas never counted." });

    var newRev = await c.ExecuteScalarAsync<int?>(Sql.CloseRound,
        new { roundId = id, siteId = me.SiteId, by = me.PersonId, rev });
    return newRev is null ? Results.NotFound() : Results.Ok(new { id, rev = newRev });
});

app.MapPost("/api/rounds/{id:guid}/signoff", async (Guid id, int rev, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    if (!me.Can("writeoff.approve")) return Forbidden("writeoff.approve");
    await using var c = await db.OpenAsync();
    // The signer-is-not-the-opener check lives in the schema; if it fires, the
    // middleware turns it into a 422 that says why.
    var newRev = await c.ExecuteScalarAsync<int?>(Sql.SignOffRound,
        new { roundId = id, siteId = me.SiteId, by = me.PersonId, rev });
    return newRev is null
        ? Results.UnprocessableEntity(new { error = "not_closed",
            message = "Only a closed audit can be signed off." })
        : Results.Ok(new { id, rev = newRev });
});

app.MapGet("/api/locations", async (Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    await using var c = await db.OpenAsync();
    return Results.Ok(await c.QueryAsync(Sql.ListLocations, new { siteId = me.SiteId }));
});

/// Stands in for a handheld so the flow can be demonstrated without one.
/// A real sweep's EPCs come from the reader; if they came from here the
/// sweep would be reading the register back to itself and could never
/// disagree with it, which is the one thing an audit exists to do.
app.MapGet("/api/locations/{id:guid}/tags-for-demo", async (Guid id, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    if (!me.Can("audit")) return Forbidden("audit");
    await using var c = await db.OpenAsync();
    return Results.Ok(await c.QueryAsync(Sql.TagsInArea, new { locationId = id }));
});

app.MapGet("/api/rounds", async (Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    await using var c = await db.OpenAsync();
    return Results.Ok(await c.QueryAsync(Sql.ListRounds, new { siteId = me.SiteId }));
});

/// The worklist an operator works from: every area in scope and where it
/// stands. Outstanding areas are the point of it.
app.MapGet("/api/rounds/{id:guid}/worklist", async (Guid id, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    await using var c = await db.OpenAsync();
    return Results.Ok(await c.QueryAsync(Sql.RoundWorklist, new { roundId = id }));
});

app.MapPost("/api/rounds/{id:guid}/skip", async (Guid id, SkipArea body, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    if (!me.Can("audit")) return Forbidden("audit");
    // A reason is not optional. An area excluded without one is indistinguishable
    // from an area nobody got to, and the report has to tell them apart.
    if (string.IsNullOrWhiteSpace(body.Reason))
        return Results.UnprocessableEntity(new { error = "reason_required",
            message = "Say why the area is being skipped. It goes on the report." });
    await using var c = await db.OpenAsync();
    await c.ExecuteAsync(Sql.SkipArea, new {
        roundId = id, locationId = body.LocationId, reason = body.Reason.Trim(), by = me.PersonId });
    return Results.Ok(new { skipped = body.LocationId });
});

/// What the sweep would conclude, without committing. The operator has to see
/// the exceptions while still standing in the area; finding out afterwards
/// means walking back.
app.MapGet("/api/sweeps/{id:guid}/preview", async (Guid id, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    await using var c = await db.OpenAsync();
    var sw = (IDictionary<string, object>)(await c.QuerySingleOrDefaultAsync(
        "SELECT * FROM tagtrail.sweep WHERE id = @id;", new { id }));
    if (sw is null) return Results.NotFound();
    var rows = await c.QueryAsync(Sql.SweepPreview, new {
        sweepId   = id,
        siteId    = me.SiteId,
        locationId= (Guid)sw["location_id"],
        floor     = (short)sw["rssi_floor"],
        asOn      = DateOnly.FromDateTime(DateTime.Today) });
    return Results.Ok(new {
        sweepId   = id,
        committed = (bool)sw["committed"],
        expected  = sw["expected_n"],
        onRegister= sw["register_n"],
        rows });
});

// ---------------------------------------------------------------------
// Sweeps
// ---------------------------------------------------------------------

app.MapGet("/api/sweeps/live", async (Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    await using var c = await db.OpenAsync();
    // What a dead battery or a shift change left behind. Offered rather than
    // lost: the browser build threw forty minutes of walking away silently.
    return Results.Ok(await c.QueryAsync(Sql.LiveSweeps, new { siteId = me.SiteId }));
});

app.MapPost("/api/sweeps", async (StartSweep body, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    if (!me.Can("audit")) return Forbidden("audit");

    await using var c = await db.OpenAsync();
    var existing = await c.QuerySingleOrDefaultAsync(Sql.LiveSweepForArea,
        new { roundId = body.RoundId, locationId = body.LocationId });
    if (existing is not null)
        return Results.Conflict(new { error = "already_scanning",
            sweepId = existing.id, operator_name = existing.operator_name, reads = existing.reads,
            message = $"{existing.operator_name} is already scanning that area with {existing.reads} tags read. "
                    + "Carry their sweep on instead of starting a second one — two sweeps of one area "
                    + "means one of them is thrown away." });

    var s = await c.QuerySingleAsync(Sql.StartSweep, new {
        siteId = me.SiteId, roundId = body.RoundId, locationId = body.LocationId,
        operatorId = me.PersonId });
    return Results.Ok(s);
});

app.MapPost("/api/sweeps/{id:guid}/reads", async (Guid id, ReadBatch body, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    if (!me.Can("audit")) return Forbidden("audit");
    if (body.Epcs.Length != body.Rssis.Length)
        return Results.UnprocessableEntity(new { error = "mismatched_batch",
            message = "Every tag read needs its signal strength." });

    // The hot path. Reads arrive in batches because a handheld streams tens a
    // second, and they land in one statement rather than one per tag.
    await using var c = await db.OpenAsync();
    await c.ExecuteAsync(Sql.UpsertReads, new { sweepId = id, body.Epcs, body.Rssis });
    return Results.Ok(new { accepted = body.Epcs.Length });
});

app.MapPost("/api/sweeps/{id:guid}/resume", async (Guid id, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    if (!me.Can("audit")) return Forbidden("audit");
    await using var c = await db.OpenAsync();
    // If a different person picks it up, the handover goes on the record. An
    // auditor asking who counted this area must not get one name when two
    // people walked it.
    var who = await c.ExecuteScalarAsync<Guid?>(Sql.RecordHandover,
        new { sweepId = id, toId = me.PersonId });
    var reads = await c.QueryAsync(Sql.SweepReads, new { sweepId = id });
    return Results.Ok(new { sweepId = id, handedOver = who is not null, reads });
});

app.MapPost("/api/sweeps/{id:guid}/commit", async (Guid id, CommitBody body, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    if (!me.Can("audit")) return Forbidden("audit");

    await using var c = await db.OpenAsync();
    await using var tx = await c.BeginTransactionAsync();

    // Read as a dictionary rather than through dynamic member access. Dapper's
    // row implements IDictionary<string, object>, and going through it keeps
    // every value's static type visible — which matters twice over: dynamic
    // cannot be deconstructed, and a null parameter whose type Dapper cannot
    // infer makes Npgsql throw at runtime rather than at build time.
    var sweepRow = (IDictionary<string, object>)(await c.QuerySingleAsync(
        "SELECT * FROM tagtrail.sweep WHERE id = @id AND NOT committed;", new { id }, tx));

    T? Col<T>(IDictionary<string, object> row, string key) =>
        row.TryGetValue(key, out var v) && v is not null && v is not DBNull ? (T)v : default;

    var asOn      = body.AsOn ?? DateOnly.FromDateTime(DateTime.Today);
    var floor     = Col<short>(sweepRow, "rssi_floor");
    var sweepArea = Col<Guid>(sweepRow, "location_id");
    var sweepRound= Col<Guid?>(sweepRow, "round_id");
    var sweepRev  = Col<int>(sweepRow, "rev");

    var readRaw = (IEnumerable<object>)await c.QueryAsync(Sql.ClassifyReads, new {
        sweepId = id, siteId = me.SiteId, locationId = sweepArea, floor }, tx);
    var read = readRaw.Cast<IDictionary<string, object>>().ToList();

    var unaccRaw = (IEnumerable<object>)await c.QueryAsync(Sql.UnaccountedAssets, new {
        sweepId = id, locationId = sweepArea, floor, asOn }, tx);
    var unaccounted = unaccRaw.Cast<IDictionary<string, object>>().ToList();

    decimal checkedValue = 0, missingValue = 0;
    var seen = new List<Guid>();

    foreach (var r in read)
    {
        var result  = Col<string>(r, "result") ?? "unknown";
        var assetId = Col<Guid?>(r, "asset_id");
        if (assetId is Guid aid) seen.Add(aid);

        await c.ExecuteAsync(Sql.InsertSweepRow, new {
            sweepId = id, result, assetId,
            epc    = Col<string>(r, "epc"),
            homeId = Col<Guid?>(r, "home_id"),
            rssi   = Col<short?>(r, "rssi_max"),
            nbv    = (decimal?)null,
            note   = Col<string>(r, "detail"),
            seenBy = (Guid?)null }, tx);
    }

    foreach (var a in unaccounted)
    {
        var assetId = Col<Guid>(a, "id");
        var status  = Col<string>(a, "status") ?? "active";
        var mobile  = Col<bool>(a, "mobile");

        // The three reasons an asset was not read are not the same finding.
        // Only the last is a discrepancy; reporting the first two as missing
        // is what fills an exception list with work nobody can do.
        var result = status is "at_repair" or "on_loan" or "in_transit" ? "offsite"
                   : mobile                                            ? "away"
                   : body.Eyeballed.Contains(assetId)                  ? "eyeballed"
                   : "missing";

        var nbv = Col<decimal?>(a, "nbv") ?? 0m;
        if (result == "missing")   missingValue += nbv;
        if (result == "eyeballed") checkedValue += nbv;

        await c.ExecuteAsync(Sql.InsertSweepRow, new {
            sweepId = id, result, assetId = (Guid?)assetId,
            epc    = Col<string>(a, "epc"),
            homeId = (Guid?)sweepArea,
            rssi   = (short?)null,
            nbv    = (decimal?)nbv,
            note   = (string?)null,
            seenBy = result == "eyeballed" ? me.PersonId : (Guid?)null }, tx);

        // Seen by eye is still verification. What it needs is a re-tag, not a
        // search party, and it must leave the value-at-risk figure.
        if (result is "missing" or "eyeballed")
            await c.ExecuteAsync(Sql.RaiseTask, new {
                siteId = me.SiteId,
                type   = result == "missing" ? "locate" : "retag",
                assetId = (Guid?)assetId,
                epc    = Col<string>(a, "epc"),
                expectedId = (Guid?)sweepArea,
                foundId = (Guid?)null,
                roundId = sweepRound,
                sweepId = id,
                teamId  = (Guid?)null,
                slaDays = 7 }, tx);
    }

    if (seen.Count > 0)
        await c.ExecuteAsync(Sql.TouchLastSeen,
            new { locationId = sweepArea, assetIds = seen.ToArray() }, tx);

    var rev = await c.ExecuteScalarAsync<int>(Sql.CommitSweep, new {
        sweepId = id, valueChecked = checkedValue, valueMissing = missingValue,
        asOn, rev = sweepRev }, tx);

    await tx.CommitAsync();
    return Results.Ok(new { sweepId = id, rev, read = read.Count, unaccounted = unaccounted.Count });
});

// ---------------------------------------------------------------------
// Tag replacement
// ---------------------------------------------------------------------

app.MapPost("/api/retags", async (RetagRequest body, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    if (!me.Can("tag")) return Forbidden("tag");

    await using var c = await db.OpenAsync();
    if (!await c.ExecuteScalarAsync<bool>(Sql.CanSign, new { personId = me.PersonId }))
        return Results.Json(new { error = "cannot_sign",
            message = "You have no PIN set, and a tag replacement has to be signed. "
                    + "An unsigned replacement is worse than none." }, statusCode: 403);

    // Verification, the move and the record are one transaction. A tag that
    // changed without a signed record beside it is precisely what this exists
    // to prevent, so a half-done replacement must not be possible.
    var newId = await c.ExecuteScalarAsync<Guid?>(Sql.ApplyRetag, new {
        siteId = me.SiteId, batchRef = body.BatchRef, assetId = body.AssetId,
        oldEpc = body.OldEpc, newEpc = body.NewEpc, reason = body.Reason,
        remarks = body.Remarks, byId = me.PersonId, pin = body.Pin, rev = body.Rev });

    if (newId is null)
        return Results.Json(new { error = "not_signed",
            message = "That PIN does not match, or the asset no longer carries that tag. "
                    + "Nothing was changed." }, statusCode: 401);

    return Results.Ok(new { id = newId });
});

// ---------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------

app.MapGet("/api/reports/round/{id:guid}", async (Guid id, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    await using var c = await db.OpenAsync();
    var report = await c.QuerySingleOrDefaultAsync(Sql.RoundReport, new { roundId = id });
    if (report is null) return Results.NotFound();
    // Cross-reads are reported beside the findings so a reviewer can see which
    // exceptions are RF physics rather than movement.
    var crossReads = await c.QueryAsync(Sql.CrossReads, new { roundId = id });
    return Results.Ok(new { report, crossReads });
});

app.MapGet("/api/reports/far", async (Db db, HttpContext ctx, DateOnly? asOn) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    await using var c = await db.OpenAsync();
    var on = asOn ?? DateOnly.FromDateTime(DateTime.Today);
    var rows = await c.QueryAsync(Sql.FixedAssetRegister, new { siteId = me.SiteId, asOn = on });

    // Downloading the whole register is the read-only auditor's one risky
    // action, so it is recorded.
    await c.ExecuteAsync(Sql.LogAccess, new {
        siteId = me.SiteId, actorId = me.PersonId, actorName = me.Name,
        @event = "export", detail = $"fixed asset register as on {on:yyyy-MM-dd}",
        device = ctx.Request.Headers.UserAgent.ToString(),
        ip = ctx.Connection.RemoteIpAddress?.ToString() });

    return Results.Ok(new { asOn = on, rows });
});

app.MapGet("/api/changelog", async (Db db, HttpContext ctx,
    string? entity, Guid? actorId, DateTime? from, DateTime? to, int page = 1, int size = 100) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    if (!me.Can("log.read")) return Forbidden("log.read");
    await using var c = await db.OpenAsync();
    var lim = Math.Clamp(size, 1, 500);
    return Results.Ok(await c.QueryAsync(Sql.ReadChangeLog, new {
        siteId = me.SiteId, entity, actorId,
        from = from ?? DateTime.UtcNow.AddYears(-10), to = to ?? DateTime.UtcNow.AddDays(1),
        limit = lim, offset = Math.Max(0, page - 1) * lim }));
});

app.MapGet("/api/reports/overdue-returns", async (Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    await using var c = await db.OpenAsync();
    // "Out for repair" must not become a parking space for anything
    // inconvenient, so an overdue return surfaces on its own.
    return Results.Ok(await c.QueryAsync(Sql.OverdueReturns, new { siteId = me.SiteId }));
});

/// Lets the console restore a session after a refresh without asking for the
/// PIN again, and tells it which role it is drawing for.
app.MapGet("/api/me", async (Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    return me is null ? Results.Unauthorized()
        : Results.Ok(new { me.PersonId, me.Name, me.EmpCode, me.Role, me.SiteId });
});

app.MapGet("/api/reports/area-population", async (Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    await using var c = await db.OpenAsync();
    // What the register holds against what a reader can even see. The gap is
    // the figure a coverage percentage must state rather than exclude.
    return Results.Ok(await c.QueryAsync(Sql.AreaPopulations, new { siteId = me.SiteId }));
});

// ---------------------------------------------------------------------
// The console's store
//
// The console already has a pluggable backend — it works against browser
// storage or a cloud document store through one interface. These three
// endpoints present the same shape over REST, so the console's own code
// barely changes: what changes is where save() sends things.
//
// Store.cs does the translation. The collections that carry statutory
// weight go to their real tables and get every guarantee; the rest are
// staged as documents until their translation is written.
// ---------------------------------------------------------------------

app.MapGet("/api/store/{col}", async (string col, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    await using var c = await db.OpenAsync();
    return Results.Ok(await Store.ReadAsync(c, me.SiteId, col));
});

/// Everything at once, which is how the console boots: it loads each
/// collection into memory and then reads synchronously. One request beats
/// fourteen on a handheld over plant wifi.
app.MapGet("/api/store", async (Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    await using var c = await db.OpenAsync();
    var cols = new[]{ "teams","locations","classes","people","assets","audits","alerts",
                      "rounds","photos","tagbatches","tagissues","retags","log","meta" };
    var all = new Dictionary<string, object>();
    foreach (var col in cols) all[col] = await Store.ReadAsync(c, me.SiteId, col);
    return Results.Ok(new { siteId = me.SiteId, collections = all,
                            mapped = Store.Mapped });
});

app.MapPut("/api/store/{col}/{id}", async (string col, string id,
    System.Text.Json.Nodes.JsonObject body, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();

    // The same permission the console checks, checked again here. The console
    // is a web page on a device anyone can open; hiding a button is not a
    // permission.
    var need = col switch {
        "assets" or "locations" or "classes" or "teams" or "people" => "register.edit",
        "rounds" or "audits" => "audit",
        "retags" or "tagbatches" or "tagissues" => "tag",
        "alerts" => "task.work",
        _ => null };
    if (need is not null && !me.Can(need)) return Forbidden(need);

    await using var c = await db.OpenAsync();
    await Store.WriteAsync(c, me.SiteId, me, col, id, body);
    return Results.Ok(new { col, id });
});

app.MapDelete("/api/store/{col}/{id}", async (string col, string id, Db db, HttpContext ctx) =>
{
    var me = await CurrentAsync(ctx, db);
    if (me is null) return Results.Unauthorized();
    if (!me.Can("register.edit")) return Forbidden("register.edit");
    await using var c = await db.OpenAsync();
    await Store.DeleteAsync(c, me.SiteId, col, id);
    return Results.Ok(new { col, id, deleted = true });
});

app.MapGet("/api/health", async (Db db) =>
{
    await using var c = await db.OpenAsync();
    // The console's own timestamp, so "is it serving my new file?" is a
    // question with an answer rather than a guess.
    var page = Path.Combine(app.Environment.WebRootPath ?? "wwwroot", "index.html");
    var built = File.Exists(page) ? File.GetLastWriteTimeUtc(page).ToString("o") : null;
    return Results.Ok(new {
        ok = await c.ExecuteScalarAsync<int>("SELECT 1;") == 1,
        consoleBuilt = built });
});

app.Run();

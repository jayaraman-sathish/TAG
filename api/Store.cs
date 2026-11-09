using System.Text.Json;
using System.Text.Json.Nodes;
using Dapper;
using Npgsql;

namespace TagTrail.Api;

/// <summary>
/// The console's store.
///
/// The console holds every record as a JSON document and reads them back
/// from memory, synchronously. The schema holds the same facts as rows,
/// which is what makes the constraints, the append-only log and the
/// stale-write check possible. This translates between the two.
///
/// Collections listed in <see cref="Mapped"/> go to their real table, and
/// get every guarantee. Everything else lands in doc_store for now, so the
/// console works against one shared database today rather than in three
/// weeks — each one moves out as its translation is written.
///
/// The translation is deliberately explicit rather than reflective. A field
/// that silently fails to map is a field that silently stops being saved,
/// and on a statutory register that is the worst possible failure: the
/// screen says it worked.
/// </summary>
public static class Store
{
    /// Collections already translated into the relational schema.
    public static readonly string[] Mapped =
        ["teams", "locations", "classes", "people", "assets"];

    public static bool IsMapped(string col) => Array.IndexOf(Mapped, col) >= 0;

    // -----------------------------------------------------------------
    // Reading
    // -----------------------------------------------------------------

    public static async Task<IEnumerable<JsonObject>> ReadAsync(
        NpgsqlConnection c, Guid siteId, string col)
    {
        switch (col)
        {
        case "teams": return Shape(await c.QueryAsync(@"
                         SELECT id, code, name, lead_name, email, rev
                           FROM tagtrail.team WHERE site_id=@s ORDER BY code;", new { s = siteId }),
                         r => new JsonObject {
                             ["id"]    = Str(r, "id"),
                             ["code"]  = Str(r, "code"),
                             ["name"]  = Str(r, "name"),
                             ["lead"]  = Str(r, "lead_name"),
                             ["email"] = Str(r, "email"),
                             ["_rev"]  = Num(r, "rev") });

        case "locations": return Shape(await c.QueryAsync(@"
                         SELECT id, code, name, area, team_id, owner_name, email, anchor_epc, rev
                           FROM tagtrail.location WHERE site_id=@s ORDER BY code;", new { s = siteId }),
                         r => new JsonObject {
                             ["id"]     = Str(r, "id"),
                             ["code"]   = Str(r, "code"),
                             ["name"]   = Str(r, "name"),
                             ["area"]   = Str(r, "area"),
                             ["team"]   = Str(r, "team_id"),
                             ["owner"]  = Str(r, "owner_name"),
                             ["email"]  = Str(r, "email"),
                             ["anchor"] = Str(r, "anchor_epc"),
                             ["_rev"]   = Num(r, "rev") });

        case "classes": return Shape(await c.QueryAsync(@"
                         SELECT id, code, name, useful_life, method::text AS method,
                                residual_pct, it_rate_pct, dept_team_id, rev
                           FROM tagtrail.asset_class WHERE site_id=@s ORDER BY code;", new { s = siteId }),
                         r => new JsonObject {
                             ["id"]          = Str(r, "id"),
                             ["code"]        = Str(r, "code"),
                             ["name"]        = Str(r, "name"),
                             ["life"]        = Num(r, "useful_life"),
                             ["method"]      = Str(r, "method"),
                             ["residualPct"] = Num(r, "residual_pct"),
                             ["itRate"]      = Num(r, "it_rate_pct"),
                             ["deptTeamId"]  = Str(r, "dept_team_id"),
                             ["_rev"]        = Num(r, "rev") });

        // The PIN hash never leaves the database. The console only needs to
        // know whether one is set, which is what it shows on the sign-in card.
        case "people": return Shape(await c.QueryAsync(@"
                         SELECT id, emp_code, name, role::text AS role, team_id, active,
                                (pin_hash IS NOT NULL) AS has_pin, rev
                           FROM tagtrail.person WHERE site_id=@s ORDER BY emp_code;", new { s = siteId }),
                         r => new JsonObject {
                             // These names are the console's, not the table's.
                             // The console reads u.empCode and u.teamId in
                             // forty places; renaming them here to match the
                             // columns meant every person screen showed a dash.
                             ["id"]      = Str(r, "id"),
                             ["empCode"] = Str(r, "emp_code"),
                             ["name"]    = Str(r, "name"),
                             ["role"]    = Str(r, "role"),
                             ["teamId"]  = Str(r, "team_id"),
                             ["active"]  = Bool(r, "active"),
                             ["hasPin"]  = Bool(r, "has_pin"),
                             ["_rev"]    = Num(r, "rev") });

        case "assets": return Shape(await c.QueryAsync(@"
                         SELECT a.id, a.code, a.name, a.category, a.home_id, a.class_id,
                                a.epc, a.tagged_at, tb.name AS tagged_by_name, a.tagged_by,
                                a.cost, a.in_use_date, a.status::text AS status, a.status_note,
                                a.due_back, a.mobile, a.custodian_id, cu.name AS custodian_name,
                                a.last_seen_id, a.last_seen_at, a.retag_count, a.rev
                           FROM tagtrail.asset a
                           LEFT JOIN tagtrail.person tb ON tb.id = a.tagged_by
                           LEFT JOIN tagtrail.person cu ON cu.id = a.custodian_id
                          WHERE a.site_id=@s ORDER BY a.code;", new { s = siteId }),
                         r => new JsonObject {
                             ["id"]           = Str(r, "id"),
                             ["code"]         = Str(r, "code"),
                             ["name"]         = Str(r, "name"),
                             ["category"]     = Str(r, "category"),
                             ["home"]         = Str(r, "home_id"),
                             ["classId"]      = Str(r, "class_id"),
                             ["epc"]          = Str(r, "epc"),
                             ["taggedAt"]     = Stamp(r, "tagged_at"),
                             ["taggedBy"]     = Str(r, "tagged_by_name"),
                             ["taggedById"]   = Str(r, "tagged_by"),
                             ["cost"]         = Num(r, "cost"),
                             ["inUseDate"]    = Date(r, "in_use_date"),
                             ["status"]       = Str(r, "status"),
                             ["statusNote"]   = Str(r, "status_note"),
                             ["dueBack"]      = Date(r, "due_back"),
                             ["mobile"]       = Bool(r, "mobile"),
                             ["custodianId"]  = Str(r, "custodian_id"),
                             ["custodian"]    = Str(r, "custodian_name"),
                             ["lastSeenLoc"]  = Str(r, "last_seen_id"),
                             ["lastSeenAt"]   = Stamp(r, "last_seen_at"),
                             ["retagCount"]   = Num(r, "retag_count"),
                             ["_rev"]         = Num(r, "rev") });

        default:
            var raw = (IEnumerable<object>)await c.QueryAsync(
                "SELECT id, body::text AS body, rev FROM tagtrail.doc_store " +
                "WHERE site_id=@s AND collection=@c;", new { s = siteId, c = col });
            var outp = new List<JsonObject>();
            foreach (var row in raw)
            {
                var d = (IDictionary<string, object>)row;
                var o = JsonNode.Parse((string)d["body"])!.AsObject();
                o["id"]   = (string)d["id"];
                o["_rev"] = (int)d["rev"];
                outp.Add(o);
            }
            return outp;
        }
    }

    // -----------------------------------------------------------------
    // Writing
    // -----------------------------------------------------------------

    public static async Task WriteAsync(
        NpgsqlConnection c, Guid siteId, Caller me, string col, string id, JsonObject body,
        NpgsqlTransaction? tx = null)
    {
        int rev = body["_rev"]?.GetValue<int>() ?? 0;

        switch (col)
        {
            case "teams":
                await c.ExecuteAsync(@"
                    INSERT INTO tagtrail.team (id, site_id, code, name, lead_name, email)
                    VALUES (@id,@s,@code,@name,@lead,@email)
                    ON CONFLICT (id) DO UPDATE SET
                        code=EXCLUDED.code, name=EXCLUDED.name,
                        lead_name=EXCLUDED.lead_name, email=EXCLUDED.email, rev=@rev;",
                    new { id = Guid.Parse(id), s = siteId,
                          code = S(body,"code"), name = S(body,"name"),
                          lead = S(body,"lead"), email = S(body,"email"), rev }, tx);
                return;

            case "locations":
                await c.ExecuteAsync(@"
                    INSERT INTO tagtrail.location (id, site_id, code, name, area, team_id,
                                                   owner_name, email, anchor_epc)
                    VALUES (@id,@s,@code,@name,@area,@team,@owner,@email,@anchor)
                    ON CONFLICT (id) DO UPDATE SET
                        code=EXCLUDED.code, name=EXCLUDED.name, area=EXCLUDED.area,
                        team_id=EXCLUDED.team_id,
                        owner_name=EXCLUDED.owner_name, email=EXCLUDED.email,
                        anchor_epc=EXCLUDED.anchor_epc, rev=@rev;",
                    new { id = Guid.Parse(id), s = siteId,
                          code = S(body,"code"), name = S(body,"name"), area = S(body,"area"),
                          team = G(body,"team"), owner = S(body,"owner"),
                          email = S(body,"email"), anchor = S(body,"anchor"), rev }, tx);
                return;

            case "classes":
                await c.ExecuteAsync(@"
                    INSERT INTO tagtrail.asset_class (id, site_id, code, name, useful_life,
                                                      method, residual_pct, it_rate_pct, dept_team_id)
                    VALUES (@id,@s,@code,@name,@life,
                            COALESCE(@method,'SLM')::tagtrail.dep_method,
                            COALESCE(@res,5.00), @itr, @dept)
                    ON CONFLICT (id) DO UPDATE SET
                        code=EXCLUDED.code, name=EXCLUDED.name, useful_life=EXCLUDED.useful_life,
                        method=EXCLUDED.method, residual_pct=EXCLUDED.residual_pct,
                        it_rate_pct=EXCLUDED.it_rate_pct, dept_team_id=EXCLUDED.dept_team_id, rev=@rev;",
                    new { id = Guid.Parse(id), s = siteId,
                          code = S(body,"code"), name = S(body,"name"),
                          life = I(body,"life"), method = S(body,"method"),
                          res = D(body,"residualPct"), itr = D(body,"itRate"),
                          dept = G(body,"deptTeamId"), rev }, tx);
                return;

            case "people":
                await c.ExecuteAsync(@"
                    INSERT INTO tagtrail.person (id, site_id, emp_code, name, role, team_id, active)
                    VALUES (@id,@s,@code,@name,COALESCE(@role,'operator')::tagtrail.user_role,
                            @team,COALESCE(@active,true))
                    ON CONFLICT (id) DO UPDATE SET
                        emp_code=EXCLUDED.emp_code, name=EXCLUDED.name, role=EXCLUDED.role,
                        team_id=EXCLUDED.team_id, active=EXCLUDED.active, rev=@rev;",
                    new { id = Guid.Parse(id), s = siteId,
                          code = S(body,"empCode"), name = S(body,"name"), role = S(body,"role"),
                          team = G(body,"teamId"), active = B(body,"active"), rev }, tx);

                // A PIN arrives in the clear exactly once, on the way to being
                // hashed, and is never stored or returned as one.
                var pin = S(body, "pin");
                if (!string.IsNullOrWhiteSpace(pin))
                    await c.ExecuteAsync("SELECT tagtrail.set_pin(@id,@pin);",
                        new { id = Guid.Parse(id), pin }, tx);
                return;

            case "assets":
                await c.ExecuteAsync(@"
                    INSERT INTO tagtrail.asset
                        (id, site_id, code, name, category, home_id, class_id, epc, tagged_at,
                         tagged_by, cost, in_use_date, status, status_note, due_back, mobile,
                         custodian_id, last_seen_id, last_seen_at, retag_count)
                    VALUES
                        (@id,@s,@code,@name,@category,@home,@class,@epc,@taggedAt,
                         @taggedBy,@cost,@inUse,COALESCE(@status,'active')::tagtrail.asset_status,
                         @note,@dueBack,COALESCE(@mobile,false),
                         @custodian,@lastLoc,@lastAt,COALESCE(@retags,0))
                    ON CONFLICT (id) DO UPDATE SET
                        code=EXCLUDED.code, name=EXCLUDED.name, category=EXCLUDED.category,
                        home_id=EXCLUDED.home_id, class_id=EXCLUDED.class_id, epc=EXCLUDED.epc,
                        tagged_at=EXCLUDED.tagged_at, tagged_by=EXCLUDED.tagged_by,
                        cost=EXCLUDED.cost, in_use_date=EXCLUDED.in_use_date,
                        status=EXCLUDED.status, status_note=EXCLUDED.status_note,
                        due_back=EXCLUDED.due_back, mobile=EXCLUDED.mobile,
                        custodian_id=EXCLUDED.custodian_id,
                        last_seen_id=EXCLUDED.last_seen_id, last_seen_at=EXCLUDED.last_seen_at,
                        retag_count=EXCLUDED.retag_count, rev=@rev;",
                    new { id = Guid.Parse(id), s = siteId,
                          code = S(body,"code"), name = S(body,"name"), category = S(body,"category"),
                          home = G(body,"home"), @class = G(body,"classId"), epc = S(body,"epc"),
                          taggedAt = T(body,"taggedAt"), taggedBy = G(body,"taggedById"),
                          cost = D(body,"cost"), inUse = Dt(body,"inUseDate"),
                          status = S(body,"status"), note = S(body,"statusNote"),
                          dueBack = Dt(body,"dueBack"), mobile = B(body,"mobile"),
                          custodian = G(body,"custodianId"),
                          lastLoc = G(body,"lastSeenLoc"), lastAt = T(body,"lastSeenAt"),
                          retags = I(body,"retagCount"), rev }, tx);
                return;

            default:
                // Staged. The document is kept whole, so nothing is lost when
                // this collection gets its own table.
                var doc = body.DeepClone().AsObject();
                doc.Remove("_rev");
                await c.ExecuteAsync(@"
                    INSERT INTO tagtrail.doc_store (site_id, collection, id, body, updated_by)
                    VALUES (@s,@c,@id,@b::jsonb,@by)
                    ON CONFLICT (site_id, collection, id) DO UPDATE SET
                        body=EXCLUDED.body, updated_by=EXCLUDED.updated_by, rev=@rev;",
                    new { s = siteId, c = col, id, b = doc.ToJsonString(),
                          by = me.PersonId, rev }, tx);
                return;
        }
    }

    public static async Task DeleteAsync(
        NpgsqlConnection c, Guid siteId, string col, string id)
    {
        var sql = col switch
        {
            "teams"     => "DELETE FROM tagtrail.team        WHERE id=@id AND site_id=@s;",
            "locations" => "DELETE FROM tagtrail.location    WHERE id=@id AND site_id=@s;",
            "classes"   => "DELETE FROM tagtrail.asset_class WHERE id=@id AND site_id=@s;",
            "people"    => "DELETE FROM tagtrail.person      WHERE id=@id AND site_id=@s;",
            "assets"    => "DELETE FROM tagtrail.asset       WHERE id=@id AND site_id=@s;",
            _           => null
        };
        if (sql is null)
        {
            await c.ExecuteAsync(
                "DELETE FROM tagtrail.doc_store WHERE site_id=@s AND collection=@c AND id=@id;",
                new { s = siteId, c = col, id });
            return;
        }
        // A foreign key may refuse this — an area still holding assets, a class
        // still in use. Db.Describe turns that into the sentence explaining why,
        // which is the behaviour the browser build could only ask for politely.
        await c.ExecuteAsync(sql, new { id = Guid.Parse(id), s = siteId });
    }

    // -----------------------------------------------------------------
    // Field readers. Explicit and null-safe: a field that fails to map is a
    // field that silently stops being saved.
    // -----------------------------------------------------------------

    static IEnumerable<JsonObject> Shape(
        IEnumerable<dynamic> rows, Func<IDictionary<string, object>, JsonObject> map)
        => ((IEnumerable<object>)rows).Cast<IDictionary<string, object>>().Select(map);

    static object? Raw(IDictionary<string, object> r, string k)
        => r.TryGetValue(k, out var v) && v is not DBNull ? v : null;

    static JsonNode? Str(IDictionary<string, object> r, string k)
        => Raw(r, k) is { } v ? JsonValue.Create(v.ToString()) : null;
    static JsonNode? Num(IDictionary<string, object> r, string k)
    {
        var v = Raw(r, k);
        if (v is null) return null;
        // One numeric type out, so the arms cannot disagree about what they
        // return and the console always gets a plain JSON number.
        try { return JsonValue.Create(Convert.ToDecimal(v)); }
        catch { return null; }
    }
    static JsonNode? Bool(IDictionary<string, object> r, string k)
        => Raw(r, k) is bool b ? JsonValue.Create(b) : null;
    static JsonNode? Stamp(IDictionary<string, object> r, string k)
        => Raw(r, k) is DateTime d ? JsonValue.Create(d.ToUniversalTime().ToString("o")) : null;
    static JsonNode? Date(IDictionary<string, object> r, string k)
        => Raw(r, k) switch {
            DateOnly d  => JsonValue.Create(d.ToString("yyyy-MM-dd")),
            DateTime dt => JsonValue.Create(dt.ToString("yyyy-MM-dd")),
            _ => null };

    /// GetValue<object>() throws on some node kinds, and ToString() on a
    /// JsonValue holding a string is not reliably the bare string. Ask for a
    /// string first and fall back only when it is genuinely something else.
    static string? S(JsonObject o, string k)
    {
        if (!o.TryGetPropertyValue(k, out var v) || v is null) return null;
        string? s = v is JsonValue jv && jv.TryGetValue<string>(out var str) ? str : v.ToString();
        return string.IsNullOrWhiteSpace(s) ? null : s;
    }
    static Guid?     G (JsonObject o, string k) => Guid.TryParse(S(o, k), out var g) ? g : null;
    static int?      I (JsonObject o, string k) => int.TryParse(S(o, k), out var i) ? i : null;
    static decimal?  D (JsonObject o, string k) => decimal.TryParse(S(o, k),
                            System.Globalization.NumberStyles.Any,
                            System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : null;
    /// The console sends a real boolean; a CSV import or a hand-edited
    /// document may send the word. Both have to mean the same thing, because
    /// "mobile" decides whether an asset is ever reported missing.
    static bool? B(JsonObject o, string k)
    {
        if (!o.TryGetPropertyValue(k, out var v) || v is not JsonValue jv) return null;
        if (jv.TryGetValue<bool>(out var b)) return b;
        if (jv.TryGetValue<string>(out var s))
            return s.Equals("true", StringComparison.OrdinalIgnoreCase)
                || s.Equals("yes",  StringComparison.OrdinalIgnoreCase)
                || s == "1";
        return null;
    }
    static DateTime? T (JsonObject o, string k) => DateTime.TryParse(S(o, k), null,
                            System.Globalization.DateTimeStyles.RoundtripKind, out var t) ? t : null;
    static DateOnly? Dt(JsonObject o, string k) => DateOnly.TryParse(S(o, k), out var d) ? d : null;
}

using System.Data;
using System.Globalization;
using Dapper;
using Npgsql;

namespace TagTrail.Api;

/// <summary>
/// Connections, and the translation of database refusals into HTTP answers.
///
/// The interesting part is <see cref="Describe"/>. The schema refuses things
/// on purpose — a stale write, a second live sweep of the same area, a
/// duplicate tag — and each refusal arrives as a Postgres error code. Letting
/// those surface as "500 Internal Server Error" would turn a correct guard
/// into what looks like a broken server, and the operator on the floor would
/// learn to press the button again.
/// </summary>
public sealed class Db(NpgsqlDataSource source)
{
    public async Task<NpgsqlConnection> OpenAsync(CancellationToken ct = default)
        => await source.OpenConnectionAsync(ct);

    /// <summary>
    /// What to tell the caller, and what the person on the other end should do
    /// about it. The message is written for whoever is holding the reader, not
    /// for the log.
    /// </summary>
    public static (int Status, string Code, string Message) Describe(PostgresException e) => e.SqlState switch
    {
        // Raised by bump_rev when the caller's rev is behind the row.
        "40001" => (409, "stale_write",
            "Somebody else changed this while you had it open. Reload it and apply your change again — "
            + "nothing was saved, so nothing of theirs was lost either."),

        // Raised by deny_change on the append-only tables.
        "42501" => (403, "append_only",
            "That record cannot be altered or deleted. The change log and tag replacements are evidence; "
            + "correct them by adding a new entry, not by editing the old one."),

        "23505" => (409, "duplicate", e.ConstraintName switch
        {
            "asset_epc_live_uniq"      => "Another asset already holds that tag. One tag means one asset — "
                                        + "if the tag has been moved, record it as a replacement.",
            "sweep_one_live_per_area"  => "Somebody is already scanning that area in this audit. "
                                        + "Open their sweep and carry it on rather than starting a second one.",
            "task_one_open_per_asset"  => "There is already an open job of that kind for this asset. "
                                        + "Its priority has been raised instead of raising a duplicate.",
            _                          => "That already exists."
        }),

        "23503" => (409, "still_referenced", e.ConstraintName switch
        {
            "round_scope_location_id_fkey" => "That area is in the scope of an audit that is still running. "
                                            + "Removing it would let the audit close as complete with the area "
                                            + "never counted. Skip it with a reason, or close the audit first.",
            "asset_home_id_fkey"           => "Assets are still allotted to that area. An asset with no area is "
                                            + "expected nowhere, so no audit would ever check it again.",
            "asset_class_id_fkey"          => "Assets still use that class. Useful life and method come from the "
                                            + "class, so removing it would drop them out of the register's totals.",
            _                              => "Something still refers to that record."
        }),

        "23514" => (422, "not_allowed", e.ConstraintName switch
        {
            "signer_is_not_the_opener"   => "An audit cannot be signed off by the person who opened it. "
                                          + "It needs a second pair of eyes before it reaches finance.",
            "due_back_only_when_away"    => "A return date only applies while an asset is out for repair, "
                                          + "on loan or in transit.",
            "depreciation_needs_a_date"  => "An asset with a cost needs the date it was put to use, "
                                          + "or no depreciation can be computed for it.",
            "retag_actually_changes_the_tag" => "The new tag is the same as the old one.",
            _                            => "That would leave the register in a state it is not allowed to be in."
        }),

        _ => (500, "database_error", "The register could not complete that. Nothing was saved.")
    };
}

/// <summary>
/// Dapper does not know what to do with a DateOnly parameter and throws
/// before the query is ever sent — which is why every endpoint that asks for
/// figures "as on" a date returned 500 while the ones that do not worked
/// perfectly. Npgsql itself handles DateOnly natively; it is only Dapper's
/// parameter binding that needs telling.
///
/// Registered once at startup. Nullable DateOnly is covered too: Dapper
/// resolves Nullable&lt;T&gt; through the handler for T.
/// </summary>
public sealed class DateOnlyHandler : SqlMapper.TypeHandler<DateOnly>
{
    public override void SetValue(IDbDataParameter parameter, DateOnly value)
    {
        parameter.DbType = DbType.Date;
        parameter.Value  = value;
    }

    public override DateOnly Parse(object value) => value switch
    {
        DateOnly d  => d,
        DateTime dt => DateOnly.FromDateTime(dt),
        string s    => DateOnly.Parse(s, CultureInfo.InvariantCulture),
        _ => throw new InvalidCastException(
                 $"Cannot read {value?.GetType().Name ?? "null"} as a date.")
    };
}

/// <summary>
/// Who is asking. Resolved per request from the signed-in session.
///
/// Permissions are checked here as well as in the UI because the UI is a web
/// page on a device anybody can open the console on. The browser build hid
/// the buttons; hiding a button is not a permission.
/// </summary>
public sealed record Caller(Guid SiteId, Guid PersonId, string Name, string EmpCode, string Role)
{
    private static readonly Dictionary<string, string[]> Grants = new()
    {
        ["viewer"]     = ["log.read"],
        ["operator"]   = ["audit", "tag", "task.work"],
        ["supervisor"] = ["audit", "tag", "task.work", "task.assign", "task.resolve",
                          "writeoff.request", "register.edit", "tagstock", "log.read"],
        ["approver"]   = ["audit", "tag", "task.work", "task.assign", "task.resolve",
                          "writeoff.request", "writeoff.approve", "register.edit", "tagstock", "log.read"],
        ["admin"]      = ["*"]
    };

    public bool Can(string permission)
        => Grants.TryGetValue(Role, out var g) && (g.Contains("*") || g.Contains(permission));
}

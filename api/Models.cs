using System.Globalization;

namespace TagTrail.Api;

// Enums mirror the database types exactly. Mapped in Program.cs so a value the
// schema would reject fails to compile here instead of at commit time, which
// on the floor means mid-sweep.

public enum AssetStatus { active, at_repair, on_loan, in_transit, scrapped, written_off }
public enum Finding     { inplace, misplaced, missing, unknown, away, offsite, retired, eyeballed }
public enum TaskKind    { locate, @return, identify, retag, retire }
public enum RetagReason { damaged, lost, wrong, service, destroyed, relabel }

public sealed record SignInRequest(Guid SiteId, string EmpCode, string? Pin);

/// Rev is what the caller read. Sending it back is how a stale write is caught
/// rather than silently overwriting whatever somebody else did in the meantime.
public sealed record AssetUpdate(
    string Code, string Name, string? Category,
    Guid? HomeId, Guid? ClassId,
    decimal? Cost, DateOnly? InUseDate,
    bool Mobile, Guid? CustodianId,
    int Rev);

public sealed record StatusChange(
    string Status, string? Note, DateOnly? DueBack,
    string Label, string PreviousStatus, int Rev);

public sealed record OpenRound(string Title, string Reason, Guid[] LocationIds);

public sealed record StartSweep(Guid RoundId, Guid LocationId);

/// Skipping an area always carries a reason. One skipped without one cannot be
/// told apart from one nobody reached, and the report has to distinguish them.
public sealed record SkipArea(Guid LocationId, string Reason);

/// Parallel arrays rather than a list of objects: a batch of five hundred
/// reads becomes two array parameters and one statement.
public sealed record ReadBatch(string[] Epcs, short[] Rssis);

/// SeenByEye carries the assets an operator confirmed by eye because the tag
/// could not be read. They are physically verified — what they need is a
/// re-tag, not a search party — so they must not land in the value at risk.
///
/// Eyeballed is a separate name rather than a property over the parameter: a
/// record cannot redeclare its own positional parameter as an auto-property.
public sealed record CommitBody(DateOnly? AsOn, Guid[]? SeenByEye)
{
    public Guid[] Eyeballed => SeenByEye ?? [];
}

public sealed record RetagRequest(
    Guid AssetId, string OldEpc, string NewEpc,
    string Reason, string? Remarks,
    string Pin,                 // verified in the database, never stored here
    Guid? BatchRef, int Rev);

/// <summary>
/// Which fields actually changed, for the change log.
///
/// The log records fields rather than whole rows on purpose: "cost 13,000 ->
/// 450,000, by Arun Prakash, 28 Oct" is what an auditor asks for. A row dump
/// before and after is not an answer to that question.
///
/// Takes a dictionary rather than dynamic. Dapper's row type implements
/// IDictionary&lt;string, object&gt;, and passing it as one keeps the call
/// statically bound — a dynamic argument makes the whole call dynamic, and a
/// dynamic result cannot be deconstructed in a foreach.
/// </summary>
public static class Diff
{
    public static IEnumerable<(string Field, string? Old, string? New)> Fields(
        IDictionary<string, object> before, AssetUpdate now)
    {
        object? Raw(string key) => before.TryGetValue(key, out var v) && v is not DBNull ? v : null;

        static string? Text(object? v) => v switch
        {
            null                 => null,
            DateTime dt          => dt.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            DateOnly d           => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            decimal m            => m.ToString("0.##", CultureInfo.InvariantCulture),
            IFormattable f       => f.ToString(null, CultureInfo.InvariantCulture),
            _                    => v.ToString()
        };

        // Compared as text, after normalising, so 13000 and 13000.00 are not
        // reported as a change and a date is not compared against its own
        // string form in a different format.
        static IEnumerable<(string, string?, string?)> One(string label, object? was, object? became)
        {
            var a = Text(was); var b = Text(became);
            if (a != b) yield return (label, a, b);
        }

        foreach (var x in One("code",             Raw("code"),        now.Code))        yield return x;
        foreach (var x in One("name",             Raw("name"),        now.Name))        yield return x;
        foreach (var x in One("category",         Raw("category"),    now.Category))    yield return x;
        foreach (var x in One("home area",        Raw("home_id"),     now.HomeId))      yield return x;
        foreach (var x in One("asset class",      Raw("class_id"),    now.ClassId))     yield return x;
        foreach (var x in One("cost",             Raw("cost"),        now.Cost))        yield return x;
        foreach (var x in One("date put to use",  Raw("in_use_date"), now.InUseDate))   yield return x;
        foreach (var x in One("custodian",        Raw("custodian_id"),now.CustodianId)) yield return x;

        // Spelled out rather than True/False: the log is read by people.
        var wasMobile = Raw("mobile") is bool m2 && m2;
        if (wasMobile != now.Mobile)
            yield return ("moves between areas", wasMobile ? "yes" : "no", now.Mobile ? "yes" : "no");
    }
}

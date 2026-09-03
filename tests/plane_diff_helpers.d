module plane_diff_helpers;

// A plane dump contains float-backed geometry widened to JSON doubles. The
// check build produced compiler-dependent gaps of up to eight ulps of the
// storage type, so the budget comes from `float`, not from a captured gap.
// Integer-looking coordinates can parse as JSON integers (`%.9g` prints 1.0
// as `1`), hence the decision is made from each pair of node types rather than
// from a plane name. The same law has an older, intentionally separate reader
// in tests/unit/undo_parity_l0_test.d (`parityDiff`).

import std.algorithm.sorting : sort;
import std.format            : format;
import std.json              : JSONType, JSONValue, parseJSON;
import std.math              : fabs, isNaN;

/// Eight ulps of the storage type. JSON's `double` is only a widening made by
/// the serializer; a tighter type would compare spellings instead of geometry.
enum double kPlaneRelTol = 8 * float.epsilon;

/// Near zero there is no relative scale, so the same storage-type budget is
/// applied against unit scale.
enum double kPlaneAbsTol = 8 * float.epsilon;

private bool isIntegerType(JSONType type)
{
    return type == JSONType.integer || type == JSONType.uinteger;
}

private bool isNumericType(JSONType type)
{
    return isIntegerType(type) || type == JSONType.float_;
}

private bool integersEqual(in JSONValue a, in JSONValue b)
{
    if (a.type == JSONType.integer && b.type == JSONType.integer)
        return a.integer == b.integer;
    if (a.type == JSONType.uinteger && b.type == JSONType.uinteger)
        return a.uinteger == b.uinteger;
    if (a.type == JSONType.integer)
        return a.integer >= 0 && cast(ulong) a.integer == b.uinteger;
    return b.integer >= 0 && a.uinteger == cast(ulong) b.integer;
}

private double asNumber(in JSONValue value)
{
    if (value.type == JSONType.float_) return value.floating;
    if (value.type == JSONType.uinteger) return cast(double) value.uinteger;
    return cast(double) value.integer;
}

/// Return an empty string when two JSON subtrees agree, otherwise a diagnostic
/// naming the first structural or leaf difference.
string leafDiff(string path, in JSONValue frozen, in JSONValue fresh)
{
    if (isNumericType(frozen.type) && isNumericType(fresh.type)) {
        // Indices, counts, marks, orders and edge ends are exact. Letting them
        // enter the floating budget would hide the topology difference this
        // comparator exists to report.
        if (isIntegerType(frozen.type) && isIntegerType(fresh.type)) {
            if (!integersEqual(frozen, fresh))
                return format("%s: frozen %s, fresh %s; integers compare exactly",
                              path, frozen.toString(), fresh.toString());
            return "";
        }

        immutable double a = asNumber(frozen);
        immutable double b = asNumber(fresh);
        if (isNaN(a) || isNaN(b)) {
            if (isNaN(a) && isNaN(b)) return "";
            return format("%s: frozen %.17g, fresh %.17g; one side is NaN",
                          path, a, b);
        }

        immutable double gap = fabs(a - b);
        immutable double scale = fabs(a) > fabs(b) ? fabs(a) : fabs(b);
        if (gap <= kPlaneAbsTol) return "";
        if (gap <= kPlaneRelTol * scale) return "";
        return format("%s: frozen %.17g, fresh %.17g"
                    ~ "\n      gap abs %.6g, rel %.6g"
                    ~ "\n      budget abs %.6g, rel %.6g (8 ulps of float)",
                      path, a, b, gap, scale > 0 ? gap / scale : gap,
                      kPlaneAbsTol, kPlaneRelTol);
    }

    if (frozen.type != fresh.type)
        return format("%s: node type frozen %s, fresh %s",
                      path, frozen.type, fresh.type);

    final switch (frozen.type) {
        case JSONType.object: {
            string[] keys;
            foreach (key, _; frozen.objectNoRef) keys ~= key;
            foreach (key, _; fresh.objectNoRef)
                if ((key in frozen.objectNoRef) is null) keys ~= key;
            keys.sort();
            foreach (key; keys) {
                auto a = key in frozen.objectNoRef;
                auto b = key in fresh.objectNoRef;
                if (a is null)
                    return format("%s.%s: new in fresh dump", path, key);
                if (b is null)
                    return format("%s.%s: gone from fresh dump", path, key);
                immutable difference =
                    leafDiff(path ~ "." ~ key, *a, *b);
                if (difference.length > 0) return difference;
            }
            return "";
        }
        case JSONType.array: {
            auto a = frozen.arrayNoRef;
            auto b = fresh.arrayNoRef;
            if (a.length != b.length)
                return format("%s: length frozen %d, fresh %d",
                              path, a.length, b.length);
            foreach (i; 0 .. a.length) {
                immutable difference =
                    leafDiff(format("%s[%d]", path, i), a[i], b[i]);
                if (difference.length > 0) return difference;
            }
            return "";
        }
        case JSONType.string:
            return frozen.str == fresh.str
                ? ""
                : format("%s: string frozen %s, fresh %s",
                         path, frozen.str, fresh.str);
        case JSONType.integer:
        case JSONType.uinteger:
        case JSONType.float_:
            return ""; // Numeric pairs returned above.
        case JSONType.true_:
        case JSONType.false_:
        case JSONType.null_:
            return ""; // Equal node types are equal values for these leaves.
    }
}

/// Every top-level plane on which two dumps disagree, sorted. Provenance is
/// metadata about the capture rather than part of the mesh state.
string[] planeDiff(string frozenText, string freshText)
{
    auto frozen = parseJSON(frozenText);
    auto fresh = parseJSON(freshText);

    bool[string] keys;
    foreach (key, _; frozen.objectNoRef) keys[key] = true;
    foreach (key, _; fresh.objectNoRef) keys[key] = true;

    string[] names;
    foreach (key, _; keys)
        if (key != "provenance") names ~= key;
    names.sort();

    string[] differences;
    foreach (name; names) {
        auto a = name in frozen.objectNoRef;
        auto b = name in fresh.objectNoRef;
        if (a is null || b is null) {
            differences ~= name;
            continue;
        }
        if (leafDiff(name, *a, *b).length > 0) differences ~= name;
    }
    return differences;
}

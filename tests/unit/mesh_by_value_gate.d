// mesh_by_value_gate — the compile-time gate every module that grows out of
// `struct Mesh` must carry (task 3160, step 1 of
// `doc/tasks/work/2910-mesh-struct-seams.md` §2.1, universal trap #1).
//
// WHAT IT CATCHES, and why no behavioural test can. `Mesh` is a COPYABLE
// struct — it has to be, because `*mesh = makeCube()` and `Layer`-by-value are
// working idioms in ~15 places. So a helper written
//
//     void reshape(Mesh m) { m.vertices.length = n; }        // by VALUE
//
// instead of `ref Mesh` COMPILES AT EVERY CALL SITE and silently drops every
// write that changes a slice's length or a field — while writes THROUGH an
// existing slice element still land, which is exactly why a subset of the
// tests around it stays green. The plan measured this as the one hazard of the
// whole seam campaign that nothing in the tree would report.
//
// It is a `static assert`, so it fires at COMPILE time in the `tests`
// configuration and the offending module never links.
//
// TWO DELIBERATE DIFFERENCES FROM THE PLAN'S PROBE, both widenings:
//   * the plan's probe read parameter 0 only; this reads EVERY parameter,
//     because a by-value `Mesh` in second position loses writes identically;
//   * `const(Mesh)` / `immutable(Mesh)` / `shared(Mesh)` are matched too — a
//     `const Mesh` by value is still an 800-byte copy, and `const ref` is the
//     spelling that means "read it where it lives".
//
// NON-VACUITY IS BUILT IN, in two places, because a gate that inspects nothing
// asserts `[] .length == 0` and passes forever:
//   * `MeshByValueGate` refuses a scope that does not contain the anchor it is
//     handed, so a mixin instantiated against the wrong symbol is an error
//     rather than a green;
//   * the `unittest` below runs the detector over `GateProbe`, which carries
//     the offender shape AND the five shapes the gate must NOT flag, and
//     asserts the answer is exactly `["byValue"]`.
module tests.unit.mesh_by_value_gate;

import mesh : Mesh;

/// The names in `scope_` (a module or an aggregate) that take a `Mesh` BY
/// VALUE in any parameter position. Empty is the only acceptable answer.
template meshByValueOffenders(alias scope_)
{
    private string[] collectOffenders()
    {
        string[] bad;
        static foreach (name; __traits(allMembers, scope_))
        {{
            static if (__traits(compiles, __traits(getOverloads, scope_, name)))
                static foreach (ov; __traits(getOverloads, scope_, name))
                {{
                    static if (is(typeof(ov) Params == __parameters))
                        static foreach (i; 0 .. Params.length)
                        {{
                            // The `alias` is LOAD-BEARING and is not style.
                            // `is(immutable(Params[i]) == immutable(Mesh))`
                            // written inline, with `i` a `static foreach`
                            // variable, answers FALSE for a parameter that IS a
                            // `Mesh` (dmd 2.112 parses `immutable(Params[i])`
                            // as an expression there). Written with a literal
                            // index it answers TRUE, which is how the draft
                            // passed its own bench and then reported ZERO
                            // offenders over `GateProbe` in the real build.
                            // The `unittest` at the bottom of this file is what
                            // caught it; keep both.
                            alias P = Params[i];
                            static if (is(immutable(P) == immutable(Mesh)))
                            {
                                enum string[] scs = [__traits(getParameterStorageClasses, ov, i)];
                                static if (!meshParamIsRefish(scs)) bad ~= name;
                            }
                        }}
                }}
        }}
        return bad;
    }
    enum string[] meshByValueOffenders = collectOffenders();
}

/// `ref` and `out` both bind the caller's mesh; everything else copies.
bool meshParamIsRefish(const string[] scs)
{
    foreach (s; scs) if (s == "ref" || s == "out") return true;
    return false;
}

/// Wire it into a module with exactly two lines at module scope:
///
///     private void byValueGateAnchor() {}
///     mixin MeshByValueGate!(__traits(parent, byValueGateAnchor));
///
/// The anchor MUST be declared at module scope and not by a mixin: a symbol a
/// mixin template declares has the mixin INSTANCE as its `__traits(parent)`,
/// and the gate would then inspect a scope holding one function — green over
/// every offender in the module.
mixin template MeshByValueGate(alias scope_)
{
    static assert(__traits(compiles, __traits(getMember, scope_, "byValueGateAnchor")),
        "MeshByValueGate was handed a scope with no `byValueGateAnchor` in it. "
      ~ "That is the vacuous instantiation: pass "
      ~ "`__traits(parent, byValueGateAnchor)` where the anchor is a MODULE-SCOPE "
      ~ "declaration of the module being gated.");
    static assert(meshByValueOffenders!scope_.length == 0,
        meshByValueOffendersMessage(meshByValueOffenders!scope_));
}

/// CTFE-built failure text, so the assert names the functions.
string meshByValueOffendersMessage(const string[] bad)
{
    string s = "these function(s) take a `Mesh` BY VALUE: ";
    foreach (i, n; bad) { if (i) s ~= ", "; s ~= "`" ~ n ~ "`"; }
    return s ~ ". A by-value `Mesh` compiles at every call site and silently "
             ~ "drops every write that changes a slice's LENGTH or a field, "
             ~ "while writes through existing slice elements still land -- so "
             ~ "part of the tests around it stay green. Take `ref Mesh` to "
             ~ "write, `const ref Mesh` to read.";
}

version (unittest)
{
    /// The gate's own positive control. One offender, five non-offenders.
    private struct GateProbe
    {
        static void byValue(Mesh m) {}
        static void okRef(ref Mesh m) {}
        static void okConstRef(const ref Mesh m) {}
        static void okOut(out Mesh m) {}
        static void okNotAMesh(int x) {}
        static void okRefSecond(int x, ref Mesh m) {}
    }
}

unittest // the detector discriminates: it finds the offender and flags nothing else
{
    static assert(meshByValueOffenders!GateProbe == ["byValue"],
        "the by-value detector answered " ~ meshByValueOffendersMessage(meshByValueOffenders!GateProbe)
      ~ " over GateProbe, which carries exactly one offender (`byValue`) and "
      ~ "five shapes it must not flag. Either it has stopped seeing by-value "
      ~ "parameters -- in which case every `length == 0` it reports elsewhere "
      ~ "is worthless -- or it has widened onto `ref`/`out`/non-Mesh.");

    // …and the NEGATIVE half, so the row above cannot be satisfied by a
    // detector that answers `["byValue"]` for structural reasons: a scope with
    // no Mesh parameter at all must answer empty, not "empty because it looked
    // at nothing" — GateProbe above proves it does look.
    static struct NoMesh { static void f(int a) {} static void g() {} }
    static assert(meshByValueOffenders!NoMesh.length == 0,
        "a scope with no `Mesh` parameter reported offenders");
}

private void byValueGateAnchor() {}
mixin MeshByValueGate!(__traits(parent, byValueGateAnchor));

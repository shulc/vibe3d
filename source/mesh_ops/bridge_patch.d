module mesh_ops.bridge_patch;
// mesh-ops-import: explicit

// Ordinary indexed open Bridge arithmetic, task 20261600, captured behavior
// 2026-10-06/08 and independent geometry-normal expectations. Projection flags
// remain unknown; unequal/missing sides fall to rails, one-side offset is deferred.
// Off-knot/2-point ghost and autoStep=false laws are static predictions. Live c3
// buffers remain unread; coefficients are reconstructed, never fitted to outputs.
import mesh : Mesh, edgeKey;
import math : Vec3;
import std.math : sqrt, floor, fabs;
import std.algorithm : max, min, reverse, sort;

struct Vec3d
{
    double[3] v = 0;
    this(double x, double y, double z)
    {
        v = [x, y, z];
    }

    this(Vec3 p)
    {
        v = [cast(double) p.x, cast(double) p.y, cast(double) p.z];
    }

    Vec3 stored() const
    {
        return Vec3(cast(float) v[0], cast(float) v[1], cast(float) v[2]);
    }

    Vec3d opBinary(string op)(Vec3d b) const if (op == "+" || op == "-")
    {
        Vec3d r;
        foreach (i; 0 .. 3)
        {
            static if (op == "+") r.v[i] = v[i] + b.v[i];
            else r.v[i] = v[i] - b.v[i];
        }
        return r;
    }

    Vec3d opBinary(string op)(double b) const if (op == "*" || op == "/")
    {
        Vec3d r;
        foreach (i; 0 .. 3)
        {
            static if (op == "*") r.v[i] = v[i] * b;
            else r.v[i] = v[i] / b;
        }
        return r;
    }
}

double dotD(Vec3d a, Vec3d b)
{
    return (a.v[0] * b.v[0] + a.v[1] * b.v[1]) + a.v[2] * b.v[2];
}

double lengthD(Vec3d a)
{
    return sqrt(dotD(a, a));
}

Vec3d unitD(Vec3d a)
{
    double n = (a.v[1] * a.v[1] + a.v[2] * a.v[2]) + a.v[0] * a.v[0];
    return n > 0 ? a * (1 / sqrt(n)) : a;
}

Vec3d crossD(Vec3d a, Vec3d b)
{
    return Vec3d(a.v[1] * b.v[2] - a.v[2] * b.v[1], a.v[2] * b.v[0] - a.v[0] * b.v[2],
            a.v[0] * b.v[1] - a.v[1] * b.v[0]);
}

private double floatLength(Vec3d a)
{
    float x = cast(float)(a.v[0] * a.v[0]), y = cast(float)(a.v[1] * a.v[1]),
        z = cast(float)(a.v[2] * a.v[2]);
    return sqrt(cast(double) cast(float)(cast(float)(x + y) + z));
}

private Vec3d floatDifference(Vec3 a, Vec3 b)
{
    return Vec3d(a - b);
}

struct BridgeNode
{
    uint v0, v1;
    int owner = -1;
}

alias BridgeGroup = BridgeNode[];
struct BridgeIncidence
{
    uint[][] neighbors;
    int[][ulong] owners;
    uint[2][ulong][int] directed;
    bool[ulong] selected;
}

BridgeIncidence bridgeIncidence(const ref Mesh m, const(uint[][]) chains)
{
    BridgeIncidence r;
    r.neighbors.length = m.vertices.length;
    foreach (chain; chains)
        foreach (i; 1 .. chain.length)
            r.selected[edgeKey(chain[i - 1], chain[i])] = true;
    foreach (fi, ring; m.faces)
        foreach (i; 0 .. ring.length)
        {
            uint a = ring[(i + ring.length - 1) % ring.length], b = ring[i];
            auto key = edgeKey(a, b);
            r.owners[key] ~= cast(int) fi;
            r.directed[cast(int) fi][key] = [a, b];
            foreach (pair; [[a, b], [b, a]])
            {
                bool found;
                foreach (v; r.neighbors[pair[0]])
                    if (v == pair[1])
                        found = true;
                if (!found)
                    r.neighbors[pair[0]] ~= pair[1];
            }
        }
    return r;
}

private int edgeOwner(ref BridgeIncidence inc, ulong key)
{
    auto p = key in inc.owners;
    return p && (*p).length ? (*p)[$ - 1] : -1;
}

BridgeGroup[] reseedOpenChains(const ref Mesh m, const(uint[][]) chains, ref BridgeIncidence inc)
{
    // Selection packet order is authoritative; chain membership is only the fallback.
    uint[] ordered;
    foreach (ei; 0 .. m.edges.length)
        if (m.isEdgeSelected(ei))
            ordered ~= cast(uint) ei;
    sort!((a, b) => m.edgeSelectionOrder[a] < m.edgeSelectionOrder[b])(ordered);
    ulong[] packets;
    foreach (ei; ordered)
    {
        if (ei < m.edges.length)
        {
            auto e = m.edges[ei];
            auto k = edgeKey(e[0], e[1]);
            if (k in inc.selected)
                packets ~= k;
        }
    }
    if (!packets.length)
        foreach (chain; chains)
            foreach (i; 1 .. chain.length)
                packets ~= edgeKey(chain[i - 1], chain[i]);
    bool[ulong] visited;
    BridgeGroup[] groups;
    foreach (key; packets)
    {
        if (key in visited)
            continue;
        int owner = edgeOwner(inc, key);
        uint[2] seed;
        if (owner >= 0)
            seed = inc.directed[owner][key];
        else
            seed = [cast(uint)(key >> 32), cast(uint) key];
        BridgeGroup g = [BridgeNode(seed[0], seed[1], owner)];
        visited[key] = true;
        foreach (head; [false, true])
            while (g[0].v0 != g[$ - 1].v1)
            {
                uint here = head ? g[0].v0 : g[$ - 1].v1;
                bool found;
                uint other;
                foreach (v; inc.neighbors[here])
                    if (edgeKey(here, v) in inc.selected && !(edgeKey(here, v) in visited))
                    {
                        other = v;
                        found = true;
                        break;
                    }
                // Ownerless disconnected row edges are absent from polygon incidence.
                if (!found)
                    foreach (chain; chains)
                        foreach (i; 1 .. chain.length)
                        {
                            auto k = edgeKey(chain[i - 1], chain[i]);
                            if (k in visited)
                                continue;
                            if (chain[i - 1] == here || chain[i] == here)
                            {
                                other = chain[i - 1] == here ? chain[i] : chain[i - 1];
                                found = true;
                                break;
                            }
                        }
                if (!found)
                    break;
                auto k = edgeKey(here, other);
                auto node = BridgeNode(head ? other : here, head ? here : other, edgeOwner(inc, k));
                g = head ? [node] ~ g : g ~ [node];
                visited[k] = true;
            }
        groups ~= g;
    }
    return groups;
}

uint[] groupNodes(const(BridgeNode)[] g)
{
    uint[] r;
    foreach (n; g)
        r ~= n.v0;
    if (g.length)
        r ~= g[$ - 1].v1;
    return r;
}

uint[] traceSide(uint start, uint target, ref BridgeIncidence inc)
{
    uint[] route = [start];
    uint here = start, previous = uint.max;
    if (inc.neighbors[here].length < 3)
        return null;
    while (true)
    {
        uint following = uint.max;
        foreach (v; inc.neighbors[here])
        {
            auto k = edgeKey(here, v);
            auto p = k in inc.owners;
            if (p && (*p).length == 1 && (previous == uint.max ? !(k in inc.selected) : v != previous))
            {
                following = v;
                break;
            }
        }
        if (following == uint.max)
            return null;
        foreach (v; route)
            if (v == following)
                return null;
        route ~= following;
        if (following == target)
            return route;
        if (inc.neighbors[following].length < 3)
            return null;
        previous = here;
        here = following;
    }
}

bool adjustOpenChains(const ref Mesh m, ref BridgeGroup[] groups,
        ref BridgeIncidence inc, int twistParity = 0)
{
    auto a = groupNodes(groups[0]), b = groupNodes(groups[1]);
    size_t best = size_t.max;
    bool flip;
    int parity = twistParity % 2;
    foreach (i, pair; [
            [a[0], b[0]], [a[0], b[$ - 1]], [a[$ - 1], b[$ - 1]], [
                a[$ - 1], b[0]
            ]
        ])
    {
        auto side = traceSide(pair[0], pair[1], inc);
        if (side.length && side.length < best)
        {
            best = side.length;
            flip = i % 2 == 1 ? !parity : !!parity;
        }
    }
    if (best == size_t.max)
    {
        double distance(uint x, uint y)
        {
            return floatLength(floatDifference(m.vertices[x], m.vertices[y]));
        }

        double same = distance(a[0], b[0]) + distance(a[$ - 1], b[$ - 1]);
        double crossed = distance(a[0], b[$ - 1]) + distance(a[$ - 1], b[0]);
        flip = same > crossed ? !parity : !!parity;
    }
    if (flip)
    {
        reverse(groups[1]);
        foreach (ref n; groups[1])
        {
            auto v = n.v0;
            n.v0 = n.v1;
            n.v1 = v;
        }
    }
    return flip;
}

alias Cubic = Vec3d[4];
private Vec3d ghost(const(Vec3d)[] points, bool end)
{
    auto a = points[end ? $ - 1 : 0].stored(), b = points[end ? $ - 2 : 1].stored();
    if (points.length == 2)
        return Vec3d(Vec3(cast(float)(2 * a.x - b.x), cast(float)(2 * a.y - b.y),
                cast(float)(2 * a.z - b.z)));
    auto c = points[end ? $ - 3 : 2].stored();
    auto d = floatDifference(a, b), e = floatDifference(b, c);
    double ld = floatLength(d), le = floatLength(e);
    double factor = le > ld ? le / ld + 2 : 3;
    return Vec3d(c) + d * factor;
}

Cubic[] cardinalCoefficients(const(Vec3d)[] points)
{
    assert(points.length >= 2);
    const(Vec3d)[] extended = [ghost(points, false)] ~ points ~ [
        ghost(points, true)
    ];
    Vec3d[] tangents;
    foreach (i; 1 .. extended.length - 1)
    {
        auto left = extended[i] - extended[i - 1], right = extended[i + 1] - extended[i];
        double l = lengthD(left), r = lengthD(right), total = l + r;
        tangents ~= total < max(total / 3360000, 1e-10) ? Vec3d.init
            : left * (r / total) + right * (l / total);
    }
    Cubic[] body;
    foreach (i; 0 .. points.length - 1)
        body ~= cubic(points[i], points[i + 1], tangents[i], tangents[i + 1]);
    return
    body;
}

Cubic cubic(Vec3d p, Vec3d q, Vec3d a, Vec3d b)
{
    return [p, a, ((q - p) * 3 - a * 2) - b, ((p - q) * 2 + a) + b];
}

Vec3d evalSpline(const(Cubic)[] body, double t)
{
    assert(body.length && t >= 0 && t <= 1);
    double raw = t * body.length;
    size_t i = min(cast(size_t) floor(raw), body.length - 1);
    double u = raw - i;
    Vec3d r;
    foreach (j; 0 .. 3)
        r.v[j] = body[i][0].v[j] + body[i][1].v[j] * u + body[i][2].v[j] * u * u
            + body[i][3].v[j] * u * u * u;
    return r;
}

uint borrowedId(const(uint)[] ids, double t)
{
    assert(ids.length && t >= 0 && t <= 1);
    return ids[cast(size_t)((ids.length - 1) * t + .5)];
}

Vec3d patchPosition(const(Cubic[][]) sources, const(Cubic[][]) sides, double s, double t)
{
    double h0(double x)
    {
        return 1 - 3 * x * x + 2 * x * x * x;
    }

    double h1(double x)
    {
        return 3 * x * x - 2 * x * x * x;
    }

    auto result = evalSpline(sources[0], s) * h0(t) + evalSpline(sources[1], s) * h1(t);
    foreach (end, curve; sides)
        if (curve.length)
        {
            auto corner = evalSpline(sources[0], end) * h0(t) + evalSpline(sources[1], end) * h1(t);
            result = result + (evalSpline(curve, t) - corner) * (end == 0 ? h0(s) : h1(s));
        }
    return result;
}

Cubic railFit(Vec3d p, Vec3d q, Vec3d left, Vec3d right, double tension, int mode)
{
    auto chord = q - p;
    Vec3d a, b;
    if (mode == 0)
        return cubic(p, q, chord, chord);
    left = unitD(left);
    right = unitD(right);
    if (mode == 1)
    {
        a = left * dotD(chord, left);
        b = right * dotD(chord, right);
    }
    else
    {
        double coupling = dotD(left, right), denominator = coupling * coupling - 4;
        auto delta = p - q;
        double al = 3 * dotD(delta, left), ar = 3 * dotD(delta, right);
        a = left * (-(coupling * ar - 2 * al) / denominator);
        b = right * (-(coupling * al - 2 * ar) / denominator);
    }
    double la = lengthD(a), lb = lengthD(b);
    if (la < max(la / 3360000, 1e-10) || lb < max(lb / 3360000, 1e-10))
    {
        a = chord;
        b = chord;
    }
    return cubic(p, q, a * tension, b * tension);
}

Vec3d groupCenter(const ref Mesh m, const(BridgeNode)[] group)
{
    auto ids = groupNodes(group);
    Vec3d r;
    foreach (id; ids)
        r = r + Vec3d(m.vertices[id]);
    return r * (1.0 / ids.length);
}

private Vec3d groupDirection(const ref Mesh m, const(BridgeNode)[] group)
{
    auto ids = groupNodes(group);
    Vec3d r;
    foreach (i; 2 .. ids.length)
    {
        auto a = m.vertices[ids[i - 2]], b = m.vertices[ids[i - 1]], c = m.vertices[ids[i]];
        auto u = a - b, v = b - c;
        Vec3 n = Vec3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x);
        float n2 = (n.y * n.y + n.z * n.z) + n.x * n.x;
        if (n2 > 0)
        {
            double inv = 1 / sqrt(cast(double) n2);
            r = r + Vec3d(Vec3(cast(float)(n.x * inv), cast(float)(n.y * inv),
                    cast(float)(n.z * inv)));
        }
    }
    return unitD(r);
}

Vec3d[2] adjustedGroupDirections(const ref Mesh m, const(BridgeNode[][]) groups)
{
    auto ca = groupCenter(m, groups[0]), cb = groupCenter(m, groups[1]);
    auto a = groupDirection(m, groups[0]), b = groupDirection(m, groups[1]);
    auto gap = cb - ca, axis = unitD(gap);
    if (!(dotD(gap, gap) > 0) || fabs(dotD(a, b)) > 0.99990000000000001)
        axis = a;
    if (dotD(axis, a) < 0)
        a = a * (-1);
    if (dotD(axis, b) < 0)
        b = b * (-1);
    auto fit = railFit(ca, cb, a, b, 1, 2);
    return [fit[1], ((gap * 3 - fit[1] * 2) - fit[2])];
}

Vec3d[2] smoothSourceDirections(const ref Mesh m, const(BridgeNode[][]) postGroups,
        size_t index, Vec3d gapDirection, Vec3d[2] adjustedDirections)
{
    Vec3d[2] outDirections;
    foreach (gi, g; postGroups)
    {
        size_t current = min(index, g.length - 1);
        auto center = groupCenter(m, g);
        Vec3d edgeDirection(size_t i)
        {
            auto node = g[i];
            uint owner = cast(uint) node.owner;
            auto normal = Vec3d(m.faceNormal(owner));
            auto a = m.vertices[node.v0], b = m.vertices[node.v1];
            auto v = unitD(crossD(floatDifference(a, b), normal));
            double sign = dotD(gapDirection, v);
            if (sign == 0)
            {
                Vec3 sum = a + b;
                sign = dotD(center - Vec3d(sum) * .5, v);
            }
            return sign < 0 ? v * (-1) : v;
        }

        if (g[current].owner < 0)
        {
            outDirections[gi] = adjustedDirections[gi];
            continue;
        }
        auto v = edgeDirection(current);
        if (current == 0 || g[current - 1].owner < 0)
        {
            outDirections[gi] = v;
            continue;
        }
        outDirections[gi] = unitD((v + edgeDirection(current - 1)) * .5);
    }
    return outDirections;
}

Vec3d[2] curveSourceDirections(const ref Mesh m, const(BridgeNode[][]) groups)
{
    auto gap = groupCenter(m, groups[1]) - groupCenter(m, groups[0]);
    return [gap, gap];
}

uint effectiveSegments(int requested, bool connect, bool autoStep,
        const(uint[][]) sides, uint cap = 512)
{
    bool admissible = sides.length == 2 && sides[0].length >= 2 && sides[0].length
        == sides[1].length;
    size_t n = connect && autoStep && admissible ? sides[0].length - 1 : cast(
            size_t) max(1, requested);
    return cast(uint) min(n, cap);
}

static foreach (n; [
        "bridgeIncidence", "reseedOpenChains", "adjustOpenChains", "traceSide",
        "cardinalCoefficients", "evalSpline", "borrowedId", "patchPosition",
        "railFit", "smoothSourceDirections", "curveSourceDirections",
        "effectiveSegments"
    ])
    static assert(!__traits(hasMember, Mesh, n));

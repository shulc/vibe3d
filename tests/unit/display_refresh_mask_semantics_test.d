// The display-refresh policy roster (tasks 5110, 5280). The full list checks
// the MeshEditScope API composition and order. Mask membership is asserted only
// for non-zero scopes: None is an API row, not a claimed behavioural cell.
module tests.unit.display_refresh_mask_semantics_test;

import std.format : format;
import std.traits : EnumMembers;

import mesh_edit_delta : DisplayRefreshMask, MeshEditScope;

private struct ScopeRow {
    string name;
    MeshEditScope scope_;
    bool refreshesDisplay;
}

private enum ScopeRow[] kScopeRoster = [
    ScopeRow("None",        MeshEditScope.None,        false),
    ScopeRow("Position",    MeshEditScope.Position,    true),
    ScopeRow("Points",      MeshEditScope.Points,      true),
    ScopeRow("Polygons",    MeshEditScope.Polygons,    true),
    ScopeRow("Marks",       MeshEditScope.Marks,       false),
    ScopeRow("Material",    MeshEditScope.Material,    true),
    ScopeRow("Visibility",  MeshEditScope.Visibility,  true),
    ScopeRow("Maps",        MeshEditScope.Maps,        true),
    ScopeRow("MapsDisplay", MeshEditScope.MapsDisplay, true),
    ScopeRow("Geometry",    MeshEditScope.Geometry,    true),
];

unittest // the API roster is complete; every non-zero scope is classified
{
    // POPULATION FLOOR first: druntime stops this module at its first failed
    // assert, so reaching a later classification proves the full stand exists.
    assert(kScopeRoster.length == 10,
        format("display refresh scope roster has %d rows; expected 10",
               kScopeRoster.length));
    assert(EnumMembers!MeshEditScope.length == kScopeRoster.length,
        format("MeshEditScope declares %d members but the fixed display roster has %d",
               EnumMembers!MeshEditScope.length, kScopeRoster.length));

    foreach (i, member; EnumMembers!MeshEditScope) {
        assert(member == kScopeRoster[i].scope_,
            format("display refresh scope roster row %d is `%s`; expected enum value %s",
                   i, kScopeRoster[i].name, member));
    }

    foreach (row; kScopeRoster) {
        const bits = cast(uint) row.scope_;
        if (bits == 0)
            continue; // None has no mask-membership observation to make.
        const included = (DisplayRefreshMask & bits) == bits;
        assert(included == row.refreshesDisplay,
            format("display refresh classification for %s is %s; expected %s",
                   row.name,
                   included ? "included" : "excluded",
                   row.refreshesDisplay ? "included" : "excluded"));
    }
}

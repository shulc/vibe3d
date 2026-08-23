module commands.ui.pie;

import std.string : strip, toLower;

import command;
import mesh;
import view;
import editmode;
import params : Param;

import pie_state : openPie, closePie;

// ---------------------------------------------------------------------------
// UiPieCommand — `ui.pie <menuId>` / `ui.pie close`
//
// Opens the radial menu named in config/pies.yaml, centred on the current
// cursor. `CmdFlags.SideEffect`: putting a menu on screen is not an edit and
// must not land in undo — the WEDGE's own action records whatever it records.
//
// It declares a `menu` PARAM rather than only reading a positional from the
// HTTP layer, and that is load-bearing rather than tidy: the keyboard binding
// (`ui.pie: "Ctrl+Space viewport"`) reaches this command through
// `runCommandWithArgs`, which injects a baked argstring THROUGH `params()`.
// With an empty schema that function drops the argument on the floor, the
// command sees "" — and "" means close. The chord would have opened nothing.
//
// The cursor comes from `eventlog.queryMouse`, not `SDL_GetMouseState`, so a
// replayed session opens the ring where the LOG says the pointer is; reading
// SDL directly would centre every replayed pie on wherever the developer's
// real mouse happened to rest.
//
// An unknown menu id REFUSES (apply → false) rather than opening an empty
// ring: the funnel turns that into `status:error` with no history entry, which
// is the honest answer for "that menu does not exist".
// ---------------------------------------------------------------------------
final class UiPieCommand : Command {
    private string menu_ = "";

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "ui.pie"; }
    override string label() const { return "Pie Menu"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override Param[] params() {
        return [ Param.string_("menu", "Menu", &menu_, "") ];
    }

    /// Positional arg: a menu id from config/pies.yaml, or "close".
    void setMenu(string arg) { menu_ = arg.strip; }

    override bool apply() {
        import pie_menus : findPieMenu;

        baseRefusal_ = "";
        immutable string id = menu_.strip;

        if (id.length == 0 || id.toLower == "close") {
            closePie();
            return true;
        }

        auto m = findPieMenu(id);
        if (m is null) {
            baseRefusal_ = "ui.pie: no menu '" ~ id ~ "' in config/pies.yaml";
            return false;
        }

        import eventlog : queryMouse;
        int mx, my;
        queryMouse(mx, my);
        openPie(m.id, mx, my, cast(int) m.items.length);
        return true;
    }
}

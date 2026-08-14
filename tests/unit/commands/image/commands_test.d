// Module unittests for `commands.image.commands`, moved verbatim out of source/commands/image/commands.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.commands.image.commands_test;

import std.path : baseName, stripExtension;
import nfde;
import command;
import mesh;
import view;
import editmode;
import params    : Param;
import document  : Document, Layer, ItemKind, ImageData;
import seltype   : SelMode;
import io.formats     : FilterSpec;
import io.image_path  : refreshImageMeta;
import change_bus     : noteLayerChange, LayerChange;
import log            : logWarn;
import commands.layer.commands : LayerDelete;
import std.file : write, remove, exists;
import std.path : buildPath;
import io.image_path : writeTestBmp, imageTestDir;
import mesh   : makeCube;
import view   : View;
import commands.image.commands;

// ---------------------------------------------------------------------------
// LOAD — an item appears, carrying the path, the derived metadata and the
// file's stem as its name.
//
// Discriminating: 3x2 (width != height), so a transposed read reads 2x3; the
// name is "alpha", which an implementation naming rows "Layer N" / "Image N"
// reads differently; and the item is NOT primary and NOT selected, which an
// implementation that copied `layer.add`'s `setActive` would break.
// ---------------------------------------------------------------------------
unittest {
    auto f = makeImgFixture("load");

    assert(f.doc.layers.length == 6, "fixture: mesh + 3 clips + 2 consumers");
    assert(f.clipA.kind == ItemKind.Image, "load produced an image-kind item");
    assert(f.clipA.hasImage && f.clipA.imageOrNull() !is null,
        "load produced a LIVE image row, not a payload-null one");

    auto img = f.clipA.imageOrNull();
    assert(img.storedPath == f.pathA, "the item carries the path it was given");
    assert(img.width  == 3, "width comes from the file header");
    assert(img.height == 2, "height comes from the file header");
    assert(!img.missing, "a file that read successfully is not missing");
    assert(f.clipA.name == "alpha",
        "the row is named after the FILE STEM — not \"Layer N\", and not the "
        ~ "full path");

    assert(f.doc.primary is f.meshA, "an image never becomes the edit target");
    assert(!f.clipA.selected,
        "load does not touch the item selection: mixing a UiState change into "
        ~ "this Model command would make one Ctrl+Z undo both");
}

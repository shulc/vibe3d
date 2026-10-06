module tests.unit.shared_hover_producers_test;

unittest {
    import std.file : readText;
    import std.path : dirName, buildPath;
    import std.string : indexOf;
    import tests.unit.census_symbols : blankNonCode, blankUnittestBodies, countIdent;
    const root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    string code(string file) { return blankUnittestBodies(blankNonCode(readText(buildPath(root,file)))); }
    const pen = code("source/tools/create/pen.d");
    assert(countIdent(pen,"hoverRecordAtPixel") == 2 &&
        pen.indexOf("sources, occlusion, false") >= 0,
        "hover production census: polygon pen must transport edited source and occlusion");
    const topo = code("source/tools/edit/topology_pen/tool.d");
    assert(countIdent(topo,"resolveHoverTarget") == 3 &&
        topo.indexOf("backgroundSourcesFull(), subject.cursorX, subject.cursorY, subject.pickOcclusion") >= 0 &&
        topo.indexOf("subject.cursorX, subject.cursorY, subject.pickOcclusion);") >= 0,
        "hover production census: both topology update doors transport source pixel and admission");
    const readout = code("source/http_providers.d");
    assert(readout.indexOf("backgroundSourcesFull(), x, y, subj.pickOcclusion") >= 0,
        "hover production census: surface readout transports query sources");
}


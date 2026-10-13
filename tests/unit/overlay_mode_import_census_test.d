// Task 6361: the overlay policy is a lower, import-free module. Every user
// imports it directly, editor_app cannot re-export or name it, and the
// viewport renderer cannot reach editor_app even through a transitive import.
module tests.unit.overlay_mode_import_census_test;


import tests.unit.census_symbols : exists = wave15Exists;

import std.algorithm : canFind, sort;
import std.array     : join, replace;
import std.file : SpanMode;
import tests.unit.census_symbols : dirEntries = wave15DirEntries, readText = wave15ReadText;
import std.format    : format;
import std.path      : buildPath, dirName, relativePath;
import std.string    : indexOf, split, startsWith, strip;

import tests.unit.census_symbols : blankNonCode, containsWord,
    countOccurrences, ImportDecl, importDeclarations, reconcile, LedgerRow,
    statementsContaining, symbolTokenHits;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum policyModule = "viewport_overlay_mode";

private struct Scan {
    bool definesMode, definesResolver;
    bool usesMode, usesResolver;          // outside import declarations
    bool importsPolicyModule;             // module list names policyModule
    bool publicImportOfPolicyModule;
    bool policyNamedInForeignImport;      // symbols name policy, module list does not
    bool importsEditorApp;
    string moduleName;
    string[] importedModules;
}

private bool inAny(size_t pos, const ImportDecl[] declarations) {
    foreach (decl; declarations)
        if (pos >= decl.start && pos < decl.end) return true;
    return false;
}

private string[] importTargets(string code, const ImportDecl[] declarations) {
    string[] result;
    foreach (decl; declarations) {
        auto list = code[decl.start + "import".length .. decl.moduleListEnd].strip;
        if (list.length && list[$ - 1] == ';') list = list[0 .. $ - 1].strip;
        foreach (binding; list.split(',')) {
            auto target = binding.strip;
            const equals = target.indexOf('=');
            if (equals >= 0) target = target[cast(size_t)equals + 1 .. $].strip;
            if (target.length) result ~= target;
        }
    }
    return result;
}

// Track D protection sections and blocks up to one import. This covers direct
// `public import`, `public: ... import`, and `public { ... import }` forms.
private bool importIsPublic(string code, size_t importAt) {
    import tests.unit.census_symbols : isIdentChar;

    bool[] publicScope = [false]; // module imports are private unless exposed
    string pendingProtection;
    size_t pos;
    while (pos < importAt) {
        if (isIdentChar(code[pos]) && !(code[pos] >= '0' && code[pos] <= '9')) {
            const start = pos++;
            while (pos < importAt && isIdentChar(code[pos])) ++pos;
            const word = code[start .. pos];
            if (word == "public" || word == "private" || word == "protected"
                || word == "package")
                pendingProtection = word;
            continue;
        }
        switch (code[pos]) {
            case ':':
                if (pendingProtection.length) {
                    publicScope[$ - 1] = pendingProtection == "public";
                    pendingProtection = null;
                }
                break;
            case '{':
                bool next = publicScope[$ - 1];
                if (pendingProtection.length)
                    next = pendingProtection == "public";
                publicScope ~= next;
                pendingProtection = null;
                break;
            case '}':
                if (publicScope.length > 1) publicScope.length--;
                pendingProtection = null;
                break;
            case ';':
                pendingProtection = null;
                break;
            default: break;
        }
        ++pos;
    }
    return pendingProtection == "public" || publicScope[$ - 1];
}

private Scan scan(string source) {
    import tests.unit.census_symbols : isIdentChar;

    const code = blankNonCode(source);
    const imports = importDeclarations(code);
    Scan result;
    result.importedModules = importTargets(code, imports);

    foreach (statement; statementsContaining(code, "module")) {
        if (statement.startsWith("module ") && statement.length > 8) {
            result.moduleName = statement["module ".length .. $ - 1].strip;
            break;
        }
    }
    foreach (decl; imports) {
        const list = code[decl.start .. decl.moduleListEnd];
        const whole = code[decl.start .. decl.end];
        if (containsWord(list, policyModule)) {
            result.importsPolicyModule = true;
            if (importIsPublic(code, decl.start))
                result.publicImportOfPolicyModule = true;
        } else if (containsWord(whole, "OverlayMode")
                   || containsWord(whole, "resolveOverlayMode")) {
            result.policyNamedInForeignImport = true;
        }
        if (containsWord(list, "editor_app")) result.importsEditorApp = true;
    }

    void words(string word, ref bool used) {
        size_t pos;
        while (pos + word.length <= code.length) {
            const rel = code[pos .. $].indexOf(word);
            if (rel < 0) break;
            const at = pos + cast(size_t)rel;
            pos = at + word.length;
            if ((at > 0 && isIdentChar(code[at - 1]))
                || (pos < code.length && isIdentChar(code[pos]))) continue;
            if (!inAny(at, imports)) used = true;
        }
    }
    words("OverlayMode", result.usesMode);
    words("resolveOverlayMode", result.usesResolver);
    foreach (statement; statementsContaining(code, "OverlayMode")) {
        if (statement.startsWith("enum OverlayMode")) result.definesMode = true;
        if (statement.startsWith("OverlayMode resolveOverlayMode(")
            && statement[$ - 1] == '{')
            result.definesResolver = true;
    }
    return result;
}

unittest // K0: scanner controls
{
    const probe = scan(q{
        module probe;
        // import editor_app : OverlayMode;  (comment)
        enum s = "import editor_app : OverlayMode;";
        import editor_app :
            EditorApp,
            OverlayMode;
        int lastOverlayMode;
    });
    assert(probe.moduleName == "probe");
    assert(probe.policyNamedInForeignImport && probe.importsEditorApp,
           "a wrapped selective import from editor_app must be seen");
    assert(!probe.usesMode && !probe.usesResolver,
           "comments, strings, imports and `lastOverlayMode` are not uses");

    const direct = scan(q{
        import viewport_overlay_mode : OverlayMode, resolveOverlayMode;
        void f() { auto m = resolveOverlayMode(0, 0, true); OverlayMode n = m; }
    });
    assert(direct.importsPolicyModule && direct.usesMode && direct.usesResolver
           && !direct.policyNamedInForeignImport);
    assert(scan(q{ public import viewport_overlay_mode; })
           .publicImportOfPolicyModule);
    assert(scan(q{ public: int intervening; import viewport_overlay_mode; })
           .publicImportOfPolicyModule,
           "a public protection section re-exports later imports");
    assert(scan(q{ public { int intervening; import viewport_overlay_mode; } })
           .publicImportOfPolicyModule,
           "a public protection block re-exports enclosed imports");
    assert(scan(q{ import ea = editor_app; }).importsEditorApp,
           "a module alias must retain its target module");
    // The K7b walk keys on `importedModules`, not on `importsEditorApp`, so the
    // alias branch needs its own witness: without it the BFS goes blind to
    // `import x = editor_app;` while every other cell here stays green (49 such
    // sites live in source/, e.g. app.d's).
    assert(scan(q{ import ea = editor_app; }).importedModules == ["editor_app"],
           "a module alias must reach the transitive walk by its target module");
}

unittest // K1-K9: whole-tree census
{
    string[] users, importers, foreign, publicImports, definers, resolverDefiners;
    string[] productionResolverUsers;
    Scan[string] productionModules;
    size_t sourceFiles, testFiles;
    Scan renderer, editorApp;
    size_t rendererSeen, editorAppSeen;
    const string[] censusRoots = ["source", "packages/command-runtime/source", "packages/application-core/source", "packages/document-model/source", "packages/param-schema/source", "packages/pipe-runtime/source", "packages/mesh-ops/source", "packages/interchange/source", "packages/interaction-query/source", "packages/pipe-evaluation/source", "packages/tool-state/source", "packages/transform-ops/source", "packages/creation-ops/source", "packages/alignment-ops/source", "packages/input-events/source", "packages/display-policy/source", "packages/viewport-gpu/source", "packages/subpatch-preview/source", "packages/edit-contracts/source", "packages/mesh-change/source", "packages/mesh-contracts/source", "packages/mesh-edit-log/source", "packages/mesh-edit-replay/source", "packages/mesh-snapshot/source", "packages/mesh-topology/source", "packages/mesh/source", "packages/profiling/source", "packages/spatial/source", "util/log/source", "util/math/source", "util/parallel/source", "util/plane-bytes/source", "util/screen-buckets/source", "tests", "packages/mesh-ops/tests/source", "packages/interchange/tests/source", "packages/interaction-query/tests/source", "packages/pipe-evaluation/tests/source", "packages/document-model/tests/source", "packages/param-schema/tests/source", "packages/pipe-runtime/tests/source", "packages/tool-state/tests/source", "packages/transform-ops/tests/source", "packages/creation-ops/tests/source", "packages/alignment-ops/tests/source", "packages/input-events/tests/source", "packages/display-policy/tests/source", "packages/viewport-gpu/tests/source", "packages/subpatch-preview/tests/source", "packages/camera-model/source", "packages/document-channels/source", "packages/image-codec/source", "packages/document-io/source", "packages/selection-model/source", "packages/scene-query/source", "packages/editor-commands/source"];
    const string[] historicalCarriers = [
        "packages/camera-model/tests/source/tests/unit/view_test.d",
        "packages/document-channels/tests/source/tests/unit/layer_params_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_test.d",
        "packages/document-io/tests/source/tests/unit/io/image_path_test.d",
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/base_revert_flag_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_apply_anchor_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_bindargs_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_registry_test.d",
        "packages/command-runtime/tests/source/tests/unit/session_edit_payload_test.d",
        "packages/application-core/tests/source/tests/unit/command_invocation_test.d",
        "packages/application-core/tests/source/tests/unit/standalone_application_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
        "packages/scene-query/tests/source/tests/unit/bvh_pick_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_projection_algorithm_cells_test.d",
];
    string[] inputPaths;
    bool[] inputProduction;
    foreach (root; censusRoots) {
        const production = root == "source"
            || root == "packages/alignment-ops/source"
            || root == "packages/command-runtime/source"
            || root == "packages/application-core/source"
            || root == "packages/creation-ops/source"
            || root == "packages/display-policy/source"
            || root == "packages/edit-contracts/source"
            || root == "packages/input-events/source"
            || root == "packages/interaction-query/source"
            || root == "packages/interchange/source"
            || root == "packages/mesh-change/source"
            || root == "packages/mesh-contracts/source"
            || root == "packages/mesh-edit-log/source"
            || root == "packages/mesh-edit-replay/source"
            || root == "packages/mesh-ops/source"
            || root == "packages/mesh-snapshot/source"
            || root == "packages/mesh-topology/source"
            || root == "packages/mesh/source"
            || root == "packages/pipe-evaluation/source"
            || root == "packages/profiling/source"
            || root == "packages/spatial/source"
            || root == "packages/subpatch-preview/source"
            || root == "packages/tool-state/source"
            || root == "packages/transform-ops/source"
            || root == "packages/viewport-gpu/source"
            || root == "util/log/source"
            || root == "util/math/source"
            || root == "util/parallel/source"
            || root == "util/plane-bytes/source"
            || root == "util/screen-buckets/source"
            || root == "packages/camera-model/source"
            || root == "packages/document-channels/source"
            || root == "packages/image-codec/source"
            || root == "packages/document-io/source"
            || root == "packages/selection-model/source"
            || root == "packages/scene-query/source"
            || root == "packages/editor-commands/source";
        foreach (de; dirEntries(buildPath(repoRoot, root), "*.d", SpanMode.depth)) {
            inputPaths ~= de.name;
            inputProduction ~= production;
        }
    }
    foreach (relative; historicalCarriers) {
        inputPaths ~= buildPath(repoRoot, relative);
        inputProduction ~= false;
    }
    foreach (relative; [
        "packages/camera-model/source",
        "packages/document-channels/source",
        "packages/image-codec/source",
        "packages/document-io/source",
        "packages/command-runtime/source",
        "packages/application-core/source",
    ]) {
        size_t occurrences;
        foreach (candidate; censusRoots) if (candidate == relative) ++occurrences;
        assert(occurrences == 1, "overlay census production root membership: " ~ relative);
    }
    foreach (relative; [
        "packages/camera-model/source/view.d",
        "packages/document-channels/source/layer_params.d",
        "packages/image-codec/source/io/image_decode.d",
        "packages/document-io/source/io/native.d",
        "packages/document-io/source/io/image_path.d",
        "packages/document-io/source/io/file_model.d",
        "packages/application-core/source/app_version.d",
        "packages/command-runtime/source/command.d",
        "packages/command-runtime/source/command_args.d",
        "packages/command-runtime/source/command_executor.d",
        "packages/command-runtime/source/command_history.d",
        "packages/command-runtime/source/command_invocation.d",
        "packages/command-runtime/source/command_registry.d",
        "packages/command-runtime/source/command_tool_policy.d",
        "packages/command-runtime/source/commands/history/redo.d",
        "packages/command-runtime/source/commands/history/undo.d",
        "packages/command-runtime/source/commands/mesh/gesture_payload.d",
        "packages/command-runtime/source/commands/mesh/mesh_edit_payload.d",
        "packages/command-runtime/source/commands/mesh/select.d",
        "packages/command-runtime/source/commands/mesh/selection_undo.d",
        "packages/command-runtime/source/commands/mesh/session_edit.d",
        "packages/command-runtime/source/commands/mesh/triple.d",
        "packages/command-runtime/source/commands/mesh/vertex_edit.d",
        "packages/command-runtime/source/commands/select/drop.d",
        "packages/command-runtime/source/commands/select/element.d",
        "packages/command-runtime/source/commands/select/invert.d",
        "packages/command-runtime/source/history_lifecycle_contract.d",
        "packages/application-core/source/http_json.d",
        "packages/application-core/source/morph_target.d",
        "packages/application-core/source/pilot_command_registration.d",
        "packages/command-runtime/source/record_observer_hub.d",
        "packages/application-core/source/session_owner.d",
        "packages/application-core/source/standalone_application.d",
        "packages/command-runtime/source/tool_activation_ownership.d",
        "packages/application-core/source/live_registration_roles.d",
        "packages/scene-query/source/bvh_pick.d",
        "packages/editor-commands/source/commands/history/clear.d",
        "packages/editor-commands/source/commands/history/save_as_script.d",
        "packages/editor-commands/source/commands/history/show.d",
        "packages/editor-commands/source/commands/macros/record.d",
        "packages/editor-commands/source/commands/macros/save_recorded.d",
        "packages/editor-commands/source/commands/mesh/add_point.d",
        "packages/editor-commands/source/commands/mesh/array_.d",
        "packages/editor-commands/source/commands/mesh/axis_slice.d",
        "packages/editor-commands/source/commands/mesh/bevel.d",
        "packages/editor-commands/source/commands/mesh/bridge.d",
        "packages/editor-commands/source/commands/mesh/cleanup.d",
        "packages/editor-commands/source/commands/mesh/clone_.d",
        "packages/editor-commands/source/commands/mesh/collapse.d",
        "packages/editor-commands/source/commands/mesh/copy_.d",
        "packages/editor-commands/source/commands/mesh/cut_.d",
        "packages/editor-commands/source/commands/mesh/delete_.d",
        "packages/editor-commands/source/commands/mesh/detriangulate.d",
        "packages/editor-commands/source/commands/mesh/duplicate_.d",
        "packages/editor-commands/source/commands/mesh/edge_crease.d",
        "packages/editor-commands/source/commands/mesh/edge_extend.d",
        "packages/editor-commands/source/commands/mesh/edge_extrude.d",
        "packages/editor-commands/source/commands/mesh/edge_join.d",
        "packages/editor-commands/source/commands/mesh/edge_slice.d",
        "packages/editor-commands/source/commands/mesh/edge_slide.d",
        "packages/editor-commands/source/commands/mesh/face_extrude.d",
        "packages/editor-commands/source/commands/mesh/fix_orientation.d",
        "packages/editor-commands/source/commands/mesh/flip.d",
        "packages/editor-commands/source/commands/mesh/hide.d",
        "packages/editor-commands/source/commands/mesh/jitter.d",
        "packages/editor-commands/source/commands/mesh/linear_align.d",
        "packages/editor-commands/source/commands/mesh/loop_slice.d",
        "packages/editor-commands/source/commands/mesh/make_polygon.d",
        "packages/editor-commands/source/commands/mesh/map_edit_undo.d",
        "packages/editor-commands/source/commands/mesh/merge.d",
        "packages/editor-commands/source/commands/mesh/mirror_.d",
        "packages/editor-commands/source/commands/mesh/morph_edit.d",
        "packages/editor-commands/source/commands/mesh/move_vertex.d",
        "packages/editor-commands/source/commands/mesh/paste_.d",
        "packages/editor-commands/source/commands/mesh/poly_inset.d",
        "packages/editor-commands/source/commands/mesh/polygon_align.d",
        "packages/editor-commands/source/commands/mesh/position_undo.d",
        "packages/editor-commands/source/commands/mesh/quadruple.d",
        "packages/editor-commands/source/commands/mesh/quantize.d",
        "packages/editor-commands/source/commands/mesh/radial_align.d",
        "packages/editor-commands/source/commands/mesh/radial_array_.d",
        "packages/editor-commands/source/commands/mesh/reduce.d",
        "packages/editor-commands/source/commands/mesh/remove_.d",
        "packages/editor-commands/source/commands/mesh/screen_slice.d",
        "packages/editor-commands/source/commands/mesh/selection_edit.d",
        "packages/editor-commands/source/commands/mesh/set_material.d",
        "packages/editor-commands/source/commands/mesh/set_part.d",
        "packages/editor-commands/source/commands/mesh/smooth_shift.d",
        "packages/editor-commands/source/commands/mesh/spikey.d",
        "packages/editor-commands/source/commands/mesh/spin_edge.d",
        "packages/editor-commands/source/commands/mesh/split_edge.d",
        "packages/editor-commands/source/commands/mesh/split_face.d",
        "packages/editor-commands/source/commands/mesh/stroke_extrude.d",
        "packages/editor-commands/source/commands/mesh/subdivide.d",
        "packages/editor-commands/source/commands/mesh/subdivide_faceted.d",
        "packages/editor-commands/source/commands/mesh/subpatch_toggle.d",
        "packages/editor-commands/source/commands/mesh/surface_attr.d",
        "packages/editor-commands/source/commands/mesh/sweep.d",
        "packages/editor-commands/source/commands/mesh/symmetrize.d",
        "packages/editor-commands/source/commands/mesh/thicken.d",
        "packages/editor-commands/source/commands/mesh/transform.d",
        "packages/editor-commands/source/commands/mesh/unify.d",
        "packages/editor-commands/source/commands/mesh/uv_map_util.d",
        "packages/editor-commands/source/commands/mesh/uv_pack.d",
        "packages/editor-commands/source/commands/mesh/uv_project.d",
        "packages/editor-commands/source/commands/mesh/uv_relax.d",
        "packages/editor-commands/source/commands/mesh/uv_transform.d",
        "packages/editor-commands/source/commands/mesh/uv_unwrap.d",
        "packages/editor-commands/source/commands/mesh/vert_join.d",
        "packages/editor-commands/source/commands/mesh/vert_merge.d",
        "packages/editor-commands/source/commands/mesh/vertex_bevel.d",
        "packages/editor-commands/source/commands/mesh/vertex_center.d",
        "packages/editor-commands/source/commands/mesh/vertex_extrude.d",
        "packages/editor-commands/source/commands/mesh/vertex_new.d",
        "packages/editor-commands/source/commands/mesh/vertex_position_result.d",
        "packages/editor-commands/source/commands/mesh/vertex_set.d",
        "packages/editor-commands/source/commands/mesh/vertex_split.d",
        "packages/editor-commands/source/commands/mesh/weightmap.d",
        "packages/editor-commands/source/commands/mesh/weld_vertex_pair.d",
        "packages/editor-commands/source/commands/select/between.d",
        "packages/editor-commands/source/commands/select/boundary.d",
        "packages/editor-commands/source/commands/select/by_stat.d",
        "packages/editor-commands/source/commands/select/by_tag.d",
        "packages/editor-commands/source/commands/select/connect.d",
        "packages/editor-commands/source/commands/select/contract.d",
        "packages/editor-commands/source/commands/select/convert.d",
        "packages/editor-commands/source/commands/select/expand.d",
        "packages/editor-commands/source/commands/select/fill.d",
        "packages/editor-commands/source/commands/select/less.d",
        "packages/editor-commands/source/commands/select/loop.d",
        "packages/editor-commands/source/commands/select/more.d",
        "packages/editor-commands/source/commands/select/ring.d",
        "packages/editor-commands/source/commands/select/sets.d",
        "packages/editor-commands/source/commands/select/type_from.d",
        "packages/editor-commands/source/macro_recorder.d",
        "packages/selection-model/source/selection_product.d",
        "packages/selection-model/source/selection_projection.d",
        "packages/editor-commands/source/step_trace.d",
        "packages/scene-query/source/symmetry_pick.d",
    ]) {
        size_t occurrences, classifiedOccurrences;
        foreach (i, candidate; inputPaths)
            if (candidate == buildPath(repoRoot, relative)) {
                ++occurrences;
                if (inputProduction[i] == true) ++classifiedOccurrences;
            }
        assert(occurrences == 1 && classifiedOccurrences == 1,
               "overlay census historical source input membership and classification: " ~ relative);
    }
    foreach (relative; [
        "packages/camera-model/tests/source/tests/unit/view_test.d",
        "packages/document-channels/tests/source/tests/unit/layer_params_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_test.d",
        "packages/document-io/tests/source/tests/unit/io/image_path_test.d",
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/base_revert_flag_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_apply_anchor_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_bindargs_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_registry_test.d",
        "packages/command-runtime/tests/source/tests/unit/session_edit_payload_test.d",
        "packages/application-core/tests/source/tests/unit/command_invocation_test.d",
        "packages/application-core/tests/source/tests/unit/standalone_application_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
        "packages/scene-query/tests/source/tests/unit/bvh_pick_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_projection_algorithm_cells_test.d",
]) {
        size_t occurrences, classifiedOccurrences;
        foreach (i, candidate; inputPaths)
            if (candidate == buildPath(repoRoot, relative)) {
                ++occurrences;
                if (inputProduction[i] == false) ++classifiedOccurrences;
            }
        assert(occurrences == 1 && classifiedOccurrences == 1,
               "overlay census historical test input membership and classification: " ~ relative);
    }
    foreach (i, inputPath; inputPaths) {
        const production = inputProduction[i];
            const rel = relativePath(inputPath, repoRoot).replace("\\", "/");
            if (production) ++sourceFiles; else ++testFiles;
            const source = readText(inputPath);
            auto found = scan(source);
            if (found.definesMode) definers ~= rel;
            if (found.definesResolver) resolverDefiners ~= rel;
            if (found.moduleName == "ui.viewport_render") {
                renderer = found;
                ++rendererSeen;
            }
            if (found.moduleName == "editor_app") {
                editorApp = found;
                ++editorAppSeen;
            }
            if (production && found.moduleName.length) {
                assert(found.moduleName !in productionModules,
                       "duplicate source module " ~ found.moduleName);
                productionModules[found.moduleName] = found;
            }
            if (found.moduleName == policyModule) continue;
            if (found.usesMode || found.usesResolver) users ~= rel;
            if (found.importsPolicyModule) importers ~= rel;
            if (found.policyNamedInForeignImport) foreign ~= rel;
            if (found.publicImportOfPolicyModule) publicImports ~= rel;
            if (production && found.usesResolver)
                productionResolverUsers ~= rel;

    }
    users.sort;
    importers.sort;
    foreign.sort;
    publicImports.sort;
    definers.sort;
    resolverDefiners.sort;
    productionResolverUsers.sort;

    // K1 population floors first.
    assert(sourceFiles >= 500 && testFiles >= 500,
           format("scanned %d source / %d test files", sourceFiles, testFiles));
    assert(rendererSeen == 1 && editorAppSeen == 1,
           format("renderer seen %d, editor_app seen %d", rendererSeen, editorAppSeen));
    assert(users.canFind("source/app.d")
           && users.canFind("source/ui/viewport_render.d"),
           format("named users missing: %s", users));

    // K2-K6: one definition, no re-export/foreign source, direct import identity.
    assert(definers == ["packages/display-policy/source/viewport_overlay_mode.d"],
           format("OverlayMode definitions: %s", definers));
    assert(resolverDefiners == ["packages/display-policy/source/viewport_overlay_mode.d"],
           format("resolveOverlayMode definitions: %s", resolverDefiners));
    assert(publicImports.length == 0, format("public re-export: %s", publicImports));
    assert(foreign.length == 0, format("policy imported from elsewhere: %s", foreign));
    assert(!editorApp.usesMode && !editorApp.usesResolver
           && !editorApp.importsPolicyModule,
           "editor_app still names the overlay policy");
    assert(users == importers, format("users %s\nimporters %s", users, importers));

    // K7: the renderer's direct dependency and the raw-literal blind spot.
    assert(!renderer.importsEditorApp,
           "ui.viewport_render still imports editor_app directly");
    assert(renderer.importsPolicyModule && renderer.usesMode,
           "ui.viewport_render does not import the policy directly");
    const rendererRaw = readText(buildPath(repoRoot, "source", "ui", "viewport_render.d"));
    assert(countOccurrences(rendererRaw, "editor_app") == 2,
           "ui.viewport_render raw editor_app count changed (expected two comments)");

    // K7b: breadth-first source import reachability, including local imports.
    enum rendererModule = "ui.viewport_render";
    string[] queue = [rendererModule];
    bool[string] reached = [rendererModule: true];
    string[string] parent;
    for (size_t head = 0; head < queue.length; ++head) {
        const current = queue[head];
        const node = current in productionModules;
        if (node is null) continue;
        foreach (next; node.importedModules) {
            if (!(next in productionModules) || next in reached) continue;
            reached[next] = true;
            parent[next] = current;
            queue ~= next;
        }
    }
    assert(queue.length >= 200,
           format("renderer import closure too small: %d modules", queue.length));
    if ("editor_app" in reached) {
        string[] chain;
        string current = "editor_app";
        while (true) {
            chain = [current] ~ chain;
            if (current == rendererModule) break;
            const previous = current in parent;
            if (previous is null) break;
            current = *previous;
        }
        assert(false, "ui.viewport_render reaches editor_app: "
               ~ chain.join(" -> "));
    }

    // K8: one production resolver call, in the owner-last loop.
    assert(productionResolverUsers == ["source/app.d"],
           format("production resolver users: %s", productionResolverUsers));
    const app = blankNonCode(readText(buildPath(repoRoot, "source", "app.d")));
    const calls = statementsContaining(app, "resolveOverlayMode(");
    assert(calls.length == 1, format("resolver call statements: %s", calls));
    const ownerLastLoops = countOccurrences(app,
        "foreach (k; overlayDrawOrder(");
    assert(ownerLastLoops == 1,
           format("owner-last overlay loops: %d", ownerLastLoops));
    const hits = symbolTokenHits(app, "source/app.d", "resolveOverlayMode(");
    const findings = reconcile([
        LedgerRow("main.frame.overlayDrawOrder", 1,
            "the owner-last N-cell loop moved unchanged into frame (task 6970)")
    ], hits);
    assert(findings.length == 0, findings);

    // K9: the one result reaches both the stamp and renderer call.
    import std.regex : ctRegex, matchFirst;
    const match = calls[0].matchFirst(
        ctRegex!`^OverlayMode\s+(\w+)\s*=\s*resolveOverlayMode\(`);
    assert(!match.empty, "resolver result is not bound to a local: " ~ calls[0]);
    const variable = match[1];
    const stamps = statementsContaining(app,
        "lastOverlayMode = cast(int)" ~ variable ~ ";");
    assert(stamps.length == 1, format("stamp statements: %s", stamps));
    size_t drawSceneWithVariable;
    foreach (statement; statementsContaining(app, "drawScene(")) {
        import std.regex : regex;
        if (!statement.matchFirst(regex(`,\s*` ~ variable ~ `\s*\)\s*;$`)).empty)
            ++drawSceneWithVariable;
    }
    assert(drawSceneWithVariable == 1,
           "the resolved mode does not reach drawScene");
}

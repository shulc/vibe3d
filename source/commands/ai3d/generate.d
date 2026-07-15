module commands.ai3d.generate;

import ai3d.stage_artifact : stageArtifact, clampGenerationDeadlineMs,
    clampMaxFaces, Ai3dMaxGenerationDeadlineMs, Ai3dDefaultRequestedFaces;
import ai3d.scene_validator : Ai3dMaxTotalFaces;

import command;
import commands.ai3d.import_result : Ai3dImportResult;
import document : Document;
import editmode;
import mesh;
import params : Param;
import view;
import viewcache;
import log : logWarn;

final class Ai3dGenerate : Command {
    private Document* doc;
    private GpuMesh* gpu;
    private VertexCache* vc;
    private EdgeCache* ec;
    private FaceBoundsCache* fc;
    private void delegate(size_t prev, size_t next) onSwitch;

    private string imageArg;
    private string workerUrlArg = "http://127.0.0.1:47831";
    private string nameArg;
    // Default = the 10-min hard ceiling (Ai3dMaxGenerationDeadlineMs). The FIRST
    // generation after a worker starts is a cold start — it loads the ~5 GB
    // TRELLIS model AND JIT-compiles the spconv / flexicubes CUDA kernels on
    // their first call, which together can exceed several minutes on a fresh
    // install / cold disk. A 2-min default made that first job time out client
    // side (BrokenPipe) even though the worker went on to finish the mesh.
    // Warm jobs still return in ~15-35 s, so a high ceiling costs steady-state
    // nothing; it only stops the cold start from being cut off.
    private int timeoutMsArg = Ai3dMaxGenerationDeadlineMs;
    private int maxFacesArg = Ai3dDefaultRequestedFaces;
    private Ai3dImportResult importer;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode);
        this.doc = doc;
        this.gpu = gpu;
        this.vc = vc;
        this.ec = ec;
        this.fc = fc;
        this.onSwitch = onSwitch;
    }

    override string name() const { return "ai3d.generate"; }
    override string label() const { return "Generate AI 3D"; }

    override Param[] params() {
        return [
            Param.string_("image", "Image", &imageArg, ""),
            Param.string_("workerUrl", "Worker URL", &workerUrlArg, "http://127.0.0.1:47831"),
            Param.string_("name", "Name", &nameArg, ""),
            // Two-layer clamp (project convention): `.enforceBounds()` is the
            // UI/injection-path clamp; `stageArtifact` (via
            // `clampGenerationDeadlineMs`) ALSO hard-caps this at the kernel
            // regardless of how the field got written, so the authoritative
            // bound doesn't depend on this Param's opt-in.
            Param.int_("timeoutMs", "Timeout (ms)", &timeoutMsArg, Ai3dMaxGenerationDeadlineMs)
                .min(1).max(Ai3dMaxGenerationDeadlineMs).enforceBounds(),
            // Two-layer clamp (same convention as timeoutMs above):
            // `.enforceBounds()` is the UI/injection-path clamp;
            // `stageArtifact` (via `clampMaxFaces`) ALSO hard-caps this at
            // the kernel regardless of how the field got written.
            Param.int_("maxFaces", "Max faces", &maxFacesArg, Ai3dDefaultRequestedFaces)
                .min(1000).max(cast(int) Ai3dMaxTotalFaces).enforceBounds(),
        ];
    }

    override bool apply() {
        if (imageArg.length == 0) return false;

        // Explicit/scripted synchronous path: no worker thread exists here,
        // so cancellation is never possible — the flag is always false.
        // stageArtifact() is the same staging seam the async controller
        // (Phase 1) drives from a worker thread; called synchronously here
        // it is behavior-identical to the pre-Phase-0 inline
        // requestArtifact()/healthCheck() logic.
        shared bool neverCancel = false;
        auto staged = stageArtifact(workerUrlArg, imageArg,
            clampGenerationDeadlineMs(timeoutMsArg), clampMaxFaces(maxFacesArg), neverCancel);
        if (!staged.ok) {
            try logWarn("ai3d", "generate failed: "
                ~ (staged.message.length ? staged.message : staged.code));
            catch (Exception) {}
            return false;
        }

        importer = new Ai3dImportResult(mesh, view, editMode, doc, gpu, vc, ec, fc, onSwitch);
        importer.setInput(staged.objPath, nameArg);
        return importer.apply();
    }

    override bool revert() {
        if (importer is null) return false;
        return importer.revert();
    }
}

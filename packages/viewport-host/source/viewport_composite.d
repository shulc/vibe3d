// The composite stage of a viewport cell (model M4, wave plan S2b, task 9190).
//
// After a cell's surface passes (which wrote the G-buffer when the cell's
// `CompositePlan` is non-empty) and before its line/overlay passes, `run`
// executes a PASS TABLE built as data by `compositePassTable`: copy the colour
// into `compositeSrcTex`, for World/Both the world-cavity raw pass into
// `aoTex[0]` and its depth-aware blur H (into `aoTex[1]`) and V (back into
// `aoTex[0]`) (wave plan S3b), then ONE resolve that writes `colorTex`. Every pass draws into the cell's
// `effectsFbo` with its C0 re-pointed per pass, so no pass samples a texture
// attached to the framebuffer it draws into (the table predicate
// `passTableViolation` is the check; tests/unit/viewport_composite_test.d).
// Every framebuffer bind and attachment goes through `applyPassTarget` and
// `restoreSceneTarget` (census in the same test). An empty plan costs ZERO GL
// calls. One compositor serves every cell: the programs are cell-independent,
// the per-cell record (`compositeRuns`, `compositeBindings`) lives in the
// cell's `ViewportFbo`. No GL call from a destructor (a GC finaliser runs off
// the GL thread): the program and VAO live for the process and are released
// with the context.
module viewport_composite;

import bindbc.opengl;
import display_state  : CavityMode, CompositePlan;
import viewport       : CompositeBinding, ViewportFbo;
import gpu_pass_timer : GpuPassTimer, GpuSeg;

/// What a pass does once its target is applied.
enum CompositePassKind : ubyte {
    /// `glBlitFramebuffer` from `readFbo` (C0) into the target, NEAREST.
    copy,
    /// The resolve program over a fullscreen triangle.
    resolve,
    /// The raw world-cavity program (S3b): samples depth + G-buffer.
    cavityRaw,
    /// The world-cavity blur along x, then along y (one program, `u_axis`).
    blurH,
    blurV,
}

/// The GL names one cell's composite reads and writes.
struct EffectIds {
    uint sceneFbo, effectsFbo;
    uint colorTex, depthTex, gbufTex, compositeSrcTex;
    uint[2] aoTex;
}

EffectIds effectIdsOf(const ref ViewportFbo f) pure nothrow @safe @nogc {
    return EffectIds(f.fbo, f.effectsFbo, f.colorTex, f.depthTex, f.gbufTex,
                     f.compositeSrcTex, f.aoTex);
}

/// One row of the pass table: the framebuffer it draws into (and, for a
/// copy, reads from), the texture attached to that framebuffer's C0, and the
/// textures it samples (0 = unit unused; unit k samples `samples[k]`).
struct CompositePass {
    CompositePassKind kind;
    uint readFbo;
    uint drawFbo;
    uint target;
    uint[4] samples;
}

/// Kernel cap on the table length (S3b's longest table is 5 rows).
enum size_t MAX_COMPOSITE_PASSES = 8;

/// A fixed-capacity pass list: built per frame without an allocation.
struct CompositePassTable {
    CompositePass[MAX_COMPOSITE_PASSES] rows;
    size_t length;
    inout(CompositePass)[] opSlice() inout return pure nothrow @safe @nogc {
        return rows[0 .. length];
    }
    void put(CompositePass p) pure nothrow @safe @nogc {
        assert(length < MAX_COMPOSITE_PASSES, "composite pass table overflow");
        rows[length++] = p;
    }
}

/// The pass table of `p` over `ids`. Empty plan: no rows. Screen: copy +
/// resolve (the screen-curvature term lives in the resolve). World and Both:
/// copy + world raw + blur H + blur V + resolve (S3b).
CompositePassTable compositePassTable(in CompositePlan p, in EffectIds ids)
    pure nothrow @safe @nogc
{
    CompositePassTable t;
    if (p.empty) return t;
    t.put(CompositePass(CompositePassKind.copy, ids.sceneFbo, ids.effectsFbo,
                        ids.compositeSrcTex, [0, 0, 0, 0]));
    if (worldCavityOn(p)) {
        t.put(CompositePass(CompositePassKind.cavityRaw, 0, ids.effectsFbo, ids.aoTex[0],
                            [ids.depthTex, ids.gbufTex, 0, 0]));
        t.put(CompositePass(CompositePassKind.blurH, 0, ids.effectsFbo, ids.aoTex[1],
                            [ids.aoTex[0], ids.depthTex, ids.gbufTex, 0]));
        t.put(CompositePass(CompositePassKind.blurV, 0, ids.effectsFbo, ids.aoTex[0],
                            [ids.aoTex[1], ids.depthTex, ids.gbufTex, 0]));
    }
    t.put(CompositePass(CompositePassKind.resolve, 0, ids.effectsFbo, ids.colorTex,
                        [ids.compositeSrcTex, ids.gbufTex, ids.aoTex[0], 0]));
    return t;
}

/// `null` iff every pass of `t` is legal over `ids`: drawn into the effects
/// framebuffer, never into a texture it samples (no feedback loop), never
/// into the G-buffer or the depth texture; a copy reads the scene framebuffer
/// into `compositeSrcTex`; the last pass is the resolve into `colorTex`.
/// Otherwise the first violation, named.
string passTableViolation(const(CompositePass)[] t, in EffectIds ids) pure @safe {
    import std.format : format;
    foreach (i, ref r; t) {
        if (r.drawFbo != ids.effectsFbo || r.drawFbo == 0)
            return format("pass %d draws into fbo %d, not the effects fbo %d", i, r.drawFbo, ids.effectsFbo);
        if (r.target == 0)
            return format("pass %d has no target", i);
        foreach (s; r.samples)
            if (s != 0 && s == r.target)
                return format("pass %d samples its own target %d (feedback loop)", i, r.target);
        if (r.target == ids.gbufTex || r.target == ids.depthTex)
            return format("pass %d targets the G-buffer or the depth texture (%d)", i, r.target);
        if (r.kind == CompositePassKind.copy
            && (r.readFbo != ids.sceneFbo || r.target != ids.compositeSrcTex))
            return format("pass %d copies fbo %d into %d, not the scene fbo into compositeSrcTex",
                          i, r.readFbo, r.target);
    }
    if (t.length > 0
        && (t[$ - 1].kind != CompositePassKind.resolve || t[$ - 1].target != ids.colorTex))
        return "the last pass must be the resolve into colorTex";
    return null;
}

/// The screen-curvature tap distance in framebuffer pixels: one LOGICAL
/// pixel, i.e. `max(1, round(framebuffer / logical width))` (wave plan S3a).
/// A non-positive width reads as scale 1.
int curvatureTapPx(int framebufferW, int logicalW) pure nothrow @safe @nogc {
    import std.math : round;
    if (framebufferW <= 0 || logicalW <= 0) return 1;
    immutable int px = cast(int) round(cast(double) framebufferW / logicalW);
    return px < 1 ? 1 : px;
}

/// The soft-limiter controls of the screen-curvature term for `p`:
/// `[0.5 / max(ridge^2, 1e-4), 0.7 / max(valley^2, 1e-4)]` (wave plan S3a).
/// The two numerators set the ceilings `2 * 0.25 / ctl`: +1.0 on a ridge,
/// -0.714 in a valley at the factors 1.
float[2] curvatureControls(in CompositePlan p) pure nothrow @safe @nogc {
    static float sq(float f) { immutable float q = f * f; return q > 1e-4f ? q : 1e-4f; }
    return [0.5f / sq(p.screenRidge), 0.7f / sq(p.screenValley)];
}

/// Whether `p` runs the world-cavity passes (S3b).
bool worldCavityOn(in CompositePlan p) pure nothrow @safe @nogc {
    return p.cavity == CavityMode.World || p.cavity == CavityMode.Both;
}

/// The inverse of a column-major 4x4 `m` (cofactor expansion); the identity
/// when `m` is singular (a projection never is).
float[16] invert4(const float[16] m) pure nothrow @safe @nogc {
    float[16] r;
    r[0]  =  m[5]*m[10]*m[15] - m[5]*m[11]*m[14] - m[9]*m[6]*m[15] + m[9]*m[7]*m[14] + m[13]*m[6]*m[11] - m[13]*m[7]*m[10];
    r[4]  = -m[4]*m[10]*m[15] + m[4]*m[11]*m[14] + m[8]*m[6]*m[15] - m[8]*m[7]*m[14] - m[12]*m[6]*m[11] + m[12]*m[7]*m[10];
    r[8]  =  m[4]*m[9]*m[15]  - m[4]*m[11]*m[13] - m[8]*m[5]*m[15] + m[8]*m[7]*m[13] + m[12]*m[5]*m[11] - m[12]*m[7]*m[9];
    r[12] = -m[4]*m[9]*m[14]  + m[4]*m[10]*m[13] + m[8]*m[5]*m[14] - m[8]*m[6]*m[13] - m[12]*m[5]*m[10] + m[12]*m[6]*m[9];
    r[1]  = -m[1]*m[10]*m[15] + m[1]*m[11]*m[14] + m[9]*m[2]*m[15] - m[9]*m[3]*m[14] - m[13]*m[2]*m[11] + m[13]*m[3]*m[10];
    r[5]  =  m[0]*m[10]*m[15] - m[0]*m[11]*m[14] - m[8]*m[2]*m[15] + m[8]*m[3]*m[14] + m[12]*m[2]*m[11] - m[12]*m[3]*m[10];
    r[9]  = -m[0]*m[9]*m[15]  + m[0]*m[11]*m[13] + m[8]*m[1]*m[15] - m[8]*m[3]*m[13] - m[12]*m[1]*m[11] + m[12]*m[3]*m[9];
    r[13] =  m[0]*m[9]*m[14]  - m[0]*m[10]*m[13] - m[8]*m[1]*m[14] + m[8]*m[2]*m[13] + m[12]*m[1]*m[10] - m[12]*m[2]*m[9];
    r[2]  =  m[1]*m[6]*m[15]  - m[1]*m[7]*m[14]  - m[5]*m[2]*m[15] + m[5]*m[3]*m[14] + m[13]*m[2]*m[7]  - m[13]*m[3]*m[6];
    r[6]  = -m[0]*m[6]*m[15]  + m[0]*m[7]*m[14]  + m[4]*m[2]*m[15] - m[4]*m[3]*m[14] - m[12]*m[2]*m[7]  + m[12]*m[3]*m[6];
    r[10] =  m[0]*m[5]*m[15]  - m[0]*m[7]*m[13]  - m[4]*m[1]*m[15] + m[4]*m[3]*m[13] + m[12]*m[1]*m[7]  - m[12]*m[3]*m[5];
    r[14] = -m[0]*m[5]*m[14]  + m[0]*m[6]*m[13]  + m[4]*m[1]*m[14] - m[4]*m[2]*m[13] - m[12]*m[1]*m[6]  + m[12]*m[2]*m[5];
    r[3]  = -m[1]*m[6]*m[11]  + m[1]*m[7]*m[10]  + m[5]*m[2]*m[11] - m[5]*m[3]*m[10] - m[9]*m[2]*m[7]   + m[9]*m[3]*m[6];
    r[7]  =  m[0]*m[6]*m[11]  - m[0]*m[7]*m[10]  - m[4]*m[2]*m[11] + m[4]*m[3]*m[10] + m[8]*m[2]*m[7]   - m[8]*m[3]*m[6];
    r[11] = -m[0]*m[5]*m[11]  + m[0]*m[7]*m[9]   + m[4]*m[1]*m[11] - m[4]*m[3]*m[9]  - m[8]*m[1]*m[7]   + m[8]*m[3]*m[5];
    r[15] =  m[0]*m[5]*m[10]  - m[0]*m[6]*m[9]   - m[4]*m[1]*m[10] + m[4]*m[2]*m[9]  + m[8]*m[1]*m[6]   - m[8]*m[2]*m[5];
    immutable float det = m[0]*r[0] + m[1]*r[4] + m[2]*r[8] + m[3]*r[12];
    if (det == 0 || det != det) {
        float[16] id = 0;
        id[0] = id[5] = id[10] = id[15] = 1;
        return id;
    }
    foreach (ref x; r) x /= det;
    return r;
}

/// Whether `p` runs the screen-curvature term.
bool screenCurvatureOn(in CompositePlan p) pure nothrow @safe @nogc {
    return p.cavity == CavityMode.Screen || p.cavity == CavityMode.Both;
}

final class ViewportCompositor {
    private GLuint resolveProgram_;
    private GLuint emptyVao_;
    private GLint  locTestGain_ = -1;
    private GLint  locCurvPx_ = -1, locRidgeCtl_ = -1, locValleyCtl_ = -1;
    private GLint  locWorldOn_ = -1;
    private GLuint rawProgram_, blurProgram_;
    private GLint  rawInvProj_ = -1, rawProjScale_ = -1, rawHomZW_ = -1, rawDistance_ = -1,
                   rawAttenuation_ = -1, rawRidge_ = -1, rawValley_ = -1, rawSamples_ = -1;
    private GLint  blurInvProj_ = -1, blurAxis_ = -1;

    /// Run the composite stage of one cell. `p.empty` ⇒ returns with ZERO GL
    /// calls and records nothing. Otherwise executes `compositePassTable`,
    /// leaves the scene FBO bound (draw + read) with every other state it
    /// touched as on entry, and records the run in `fbo`. `tapPx` is the
    /// screen-curvature tap distance (`curvatureTapPx`); `proj` the cell's
    /// projection (column-major), read by the world-cavity passes.
    void run(in CompositePlan p, ref ViewportFbo fbo, int cellW, int cellH,
             int tapPx, const ref float[16] proj, ref GpuPassTimer timer) {
        if (p.empty) return;
        timer.mark(GpuSeg.composite);
        ensureProgram();
        immutable EffectIds ids = effectIdsOf(fbo);
        immutable CompositePassTable table = compositePassTable(p, ids);
        assert(passTableViolation(table[], ids) is null, passTableViolation(table[], ids));

        // ---- entry state (every read through glGetIntegerv / glIsEnabled:
        // both are in the web roster, glGetBooleanv is not) ----
        GLint prevProgram, prevVao, prevActive, prevDepthMask;
        GLint[4] prevViewport;
        GLint[3] prevTex;
        glGetIntegerv(GL_CURRENT_PROGRAM, &prevProgram);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &prevVao);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &prevActive);
        glGetIntegerv(GL_DEPTH_WRITEMASK, &prevDepthMask);
        glGetIntegerv(GL_VIEWPORT, prevViewport.ptr);
        foreach (u; 0 .. 3) {
            glActiveTexture(GL_TEXTURE0 + u);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &prevTex[u]);
        }
        immutable bool depthTest = glIsEnabled(GL_DEPTH_TEST) != 0;
        immutable bool blend     = glIsEnabled(GL_BLEND) != 0;
        immutable bool cull      = glIsEnabled(GL_CULL_FACE) != 0;
        immutable bool scissor   = glIsEnabled(GL_SCISSOR_TEST) != 0;
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_BLEND);
        glDisable(GL_CULL_FACE);
        glDisable(GL_SCISSOR_TEST);   // a blit and a draw both honour it

        fbo.compositeBindings.length = 0;
        fbo.compositeBindings.assumeSafeAppend();
        immutable bool worldOn = worldCavityOn(p);
        immutable float[16] invProj = invert4(proj);
        foreach (ref pass; table[]) {
            applyPassTarget(pass);
            if (pass.kind == CompositePassKind.copy) {
                recordBinding(fbo, pass);
                glBlitFramebuffer(0, 0, cellW, cellH, 0, 0, cellW, cellH,
                                  GL_COLOR_BUFFER_BIT, GL_NEAREST);
                continue;
            }
            // A fullscreen-triangle pass: its program and uniforms, then the
            // one draw below. Unit k samples `pass.samples[k]`.
            final switch (pass.kind) {
                case CompositePassKind.copy:
                    assert(false, "the copy is drawn above");
                case CompositePassKind.cavityRaw:
                    timer.mark(GpuSeg.cavityRaw);
                    glUseProgram(rawProgram_);
                    glUniformMatrix4fv(rawInvProj_, 1, GL_FALSE, invProj.ptr);
                    glUniform2f(rawProjScale_, proj[0] * cellW * 0.5f, proj[5] * cellH * 0.5f);
                    glUniform2f(rawHomZW_, proj[11], proj[15]);
                    glUniform1f(rawDistance_, p.distance);
                    glUniform1f(rawAttenuation_, p.attenuation);
                    glUniform1f(rawRidge_, p.worldRidge);
                    glUniform1f(rawValley_, p.worldValley);
                    glUniform1i(rawSamples_, p.samples);
                    break;
                case CompositePassKind.blurH:
                case CompositePassKind.blurV:
                    timer.mark(GpuSeg.cavityBlur);
                    glUseProgram(blurProgram_);
                    glUniformMatrix4fv(blurInvProj_, 1, GL_FALSE, invProj.ptr);
                    // vec2 (glUniform2i is not in the web GL roster)
                    if (pass.kind == CompositePassKind.blurH) glUniform2f(blurAxis_, 1, 0);
                    else                                      glUniform2f(blurAxis_, 0, 1);
                    break;
                case CompositePassKind.resolve:
                    if (worldOn) timer.mark(GpuSeg.composite);   // the resolve, after the world passes
                    glUseProgram(resolveProgram_);
                    glUniform1f(locTestGain_, fbo.compositeTestGain);
                    immutable float[2] ctl = curvatureControls(p);
                    glUniform1i(locCurvPx_, screenCurvatureOn(p) ? tapPx : 0);
                    glUniform1f(locRidgeCtl_, ctl[0]);
                    glUniform1f(locValleyCtl_, ctl[1]);
                    glUniform1i(locWorldOn_, worldOn ? 1 : 0);
                    break;
            }
            glViewport(0, 0, cellW, cellH);
            glBindVertexArray(emptyVao_);
            foreach (u; 0 .. 3) {
                glActiveTexture(GL_TEXTURE0 + u);
                glBindTexture(GL_TEXTURE_2D, pass.samples[u]);
            }
            recordBinding(fbo, pass);
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
        restoreSceneTarget(fbo.fbo);

        // ---- restore ----
        foreach (u; 0 .. 3) {
            glActiveTexture(GL_TEXTURE0 + u);
            glBindTexture(GL_TEXTURE_2D, cast(GLuint)prevTex[u]);
        }
        glActiveTexture(cast(GLenum)prevActive);
        glBindVertexArray(cast(GLuint)prevVao);
        glUseProgram(cast(GLuint)prevProgram);
        glViewport(prevViewport[0], prevViewport[1], prevViewport[2], prevViewport[3]);
        if (depthTest) glEnable(GL_DEPTH_TEST);
        if (blend)     glEnable(GL_BLEND);
        if (cull)      glEnable(GL_CULL_FACE);
        if (scissor)   glEnable(GL_SCISSOR_TEST);
        ++fbo.compositeRuns;

        debug {
            fbo.compositeChecked = true;
            immutable string fault = postconditionError(ids, prevProgram, prevVao,
                prevDepthMask, prevViewport, prevTex, depthTest, blend, cull, scissor);
            if (fault !is null) fbo.noteCompositeFault(fault);
        }
    }

    /// Debug builds: the stage's postcondition, read back from GL — the scene
    /// FBO bound for draw and read, draw buffers {C0}, read buffer C0, and the
    /// state it touched as on entry; the active unit is GL_TEXTURE0 and no
    /// effect texture is left bound on units 0-2 (absolute: a leak repeated
    /// every frame would equal its own entry state). `null` or the first
    /// violation, counted per cell (`/api/viewport/display` "compositeFaults")
    /// so a suite cell reads it instead of a debug assert ending the process.
    debug private static string postconditionError(in EffectIds ids, GLint prog0, GLint vao0,
            GLint mask0, const GLint[4] vp0, const GLint[3] tex0,
            bool depthTest, bool blend, bool cull, bool scissor) {
        immutable uint sceneFbo = ids.sceneFbo;
        GLint dr, rd, db0, db1, rb, prog, vao, act, mask;
        GLint[4] vpNow;
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &dr);
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &rd);
        glGetIntegerv(GL_DRAW_BUFFER0, &db0);
        glGetIntegerv(GL_DRAW_BUFFER1, &db1);
        glGetIntegerv(GL_READ_BUFFER, &rb);
        glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &act);
        glGetIntegerv(GL_DEPTH_WRITEMASK, &mask);
        glGetIntegerv(GL_VIEWPORT, vpNow.ptr);
        if (dr != sceneFbo || rd != sceneFbo) return "scene FBO not re-bound for draw and read";
        if (db0 != GL_COLOR_ATTACHMENT0 || db1 != GL_NONE) return "scene draw buffers are not {C0}";
        if (rb != GL_COLOR_ATTACHMENT0) return "scene read buffer is not C0";
        if (prog != prog0) return "program not restored";
        if (vao != vao0) return "vertex array not restored";
        if (act != GL_TEXTURE0) return "active texture unit is not GL_TEXTURE0";
        if (mask != mask0) return "depth mask not restored";
        if (vpNow != vp0) return "viewport not restored";
        if ((glIsEnabled(GL_DEPTH_TEST) != 0) != depthTest) return "depth test not restored";
        if ((glIsEnabled(GL_BLEND) != 0) != blend) return "blend not restored";
        if ((glIsEnabled(GL_CULL_FACE) != 0) != cull) return "cull face not restored";
        if ((glIsEnabled(GL_SCISSOR_TEST) != 0) != scissor) return "scissor test not restored";
        foreach (u; 0 .. 3) {
            GLint t;
            glActiveTexture(GL_TEXTURE0 + u);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &t);
            immutable bool ours = t != 0 && (t == ids.compositeSrcTex || t == ids.gbufTex
                                             || t == ids.depthTex
                                             || t == ids.aoTex[0] || t == ids.aoTex[1]);
            if (t != tex0[u] || ours) {
                glActiveTexture(cast(GLenum)act);
                return ours ? "an effect texture is left bound" : "texture unit binding not restored";
            }
        }
        glActiveTexture(cast(GLenum)act);
        return null;
    }

    /// The ONE place a pass's framebuffers are bound and its C0 attached.
    private void applyPassTarget(const ref CompositePass pass) {
        if (pass.kind == CompositePassKind.copy) {
            glBindFramebuffer(GL_READ_FRAMEBUFFER, pass.readFbo);
            glReadBuffer(GL_COLOR_ATTACHMENT0);
        }
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, pass.drawFbo);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D, pass.target, 0);
    }

    /// Back to the scene FBO (draw and read) after the pass loop.
    private void restoreSceneTarget(uint sceneFbo) {
        glBindFramebuffer(GL_FRAMEBUFFER, sceneFbo);
    }

    /// The draw framebuffer as GL reports it immediately BEFORE the pass's
    /// draw call, with the texture `applyPassTarget` attached.
    private void recordBinding(ref ViewportFbo fbo, const ref CompositePass pass) {
        GLint bound;
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &bound);
        fbo.compositeBindings ~= CompositeBinding(cast(uint)bound, pass.target);
    }

    private void ensureProgram() {
        if (resolveProgram_ != 0) return;
        import shader : createProgram, compositeVertSrc, compositeResolveFragSrc;
        resolveProgram_ = createProgram(compositeVertSrc, compositeResolveFragSrc);
        glGenVertexArrays(1, &emptyVao_);
        GLint prev;
        glGetIntegerv(GL_CURRENT_PROGRAM, &prev);
        glUseProgram(resolveProgram_);
        glUniform1i(glGetUniformLocation(resolveProgram_, "u_src"), 0);
        glUniform1i(glGetUniformLocation(resolveProgram_, "u_gbuf"), 1);
        glUniform1i(glGetUniformLocation(resolveProgram_, "u_ao"), 2);
        locTestGain_ = glGetUniformLocation(resolveProgram_, "u_testGain");
        locCurvPx_     = glGetUniformLocation(resolveProgram_, "u_curvPx");
        locRidgeCtl_   = glGetUniformLocation(resolveProgram_, "u_ridgeCtl");
        locValleyCtl_  = glGetUniformLocation(resolveProgram_, "u_valleyCtl");
        locWorldOn_    = glGetUniformLocation(resolveProgram_, "u_worldOn");

        import shader : worldCavityFragSrc, cavityBlurFragSrc;
        rawProgram_ = createProgram(compositeVertSrc, worldCavityFragSrc);
        glUseProgram(rawProgram_);
        glUniform1i(glGetUniformLocation(rawProgram_, "u_depth"), 0);
        glUniform1i(glGetUniformLocation(rawProgram_, "u_gbuf"), 1);
        rawInvProj_     = glGetUniformLocation(rawProgram_, "u_invProj");
        rawProjScale_   = glGetUniformLocation(rawProgram_, "u_projScale");
        rawHomZW_       = glGetUniformLocation(rawProgram_, "u_homZW");
        rawDistance_    = glGetUniformLocation(rawProgram_, "u_distance");
        rawAttenuation_ = glGetUniformLocation(rawProgram_, "u_attenuation");
        rawRidge_       = glGetUniformLocation(rawProgram_, "u_ridge");
        rawValley_      = glGetUniformLocation(rawProgram_, "u_valley");
        rawSamples_     = glGetUniformLocation(rawProgram_, "u_samples");

        blurProgram_ = createProgram(compositeVertSrc, cavityBlurFragSrc);
        glUseProgram(blurProgram_);
        glUniform1i(glGetUniformLocation(blurProgram_, "u_ao"), 0);
        glUniform1i(glGetUniformLocation(blurProgram_, "u_depth"), 1);
        glUniform1i(glGetUniformLocation(blurProgram_, "u_gbuf"), 2);
        blurInvProj_ = glGetUniformLocation(blurProgram_, "u_invProj");
        blurAxis_    = glGetUniformLocation(blurProgram_, "u_axis");
        glUseProgram(cast(GLuint)prev);
    }
}

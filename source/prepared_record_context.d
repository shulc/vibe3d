module prepared_record_context;

// P1.0b.3d dormant producer context. Production activation doors do not import
// or construct this until the single P1.0c unified cutover.
import command : Command;
import command_history : CommandHistory, PreparedHistoryKind,
                         PreparedHistoryResult, PreparedHistoryToken,
                         ValidatedPreparedHistoryToken;
import record_observer_hub : RecordObserverHub;
import mesh : Mesh;
import mesh_gpu : GpuResourceOwner, GpuUploadOwner, GpuCreateOwner,
                  GpuCreateUploadOwner;
import handler : ClickPointResourceOwner, BoxHandlerBatchResourceOwner;
import snap_render : SnapOverlayOwner;
import prepared_private_state : PreparedPrivateStateOwner, PreparedPrivateStateKind;
import prepared_selection_profile : PreparedSelectionProfileOwner;
import prepared_radial_sweep_transition : PreparedRadialSweepTransitionOwner;
import prepared_radial_array_transition : PreparedRadialArrayTransitionOwner;
import prepared_transform_activation : PreparedTransformActivationOwner;
import prepared_transform_product_activation : PreparedTransformProductActivationOwner;
import prepared_move_update : PreparedMoveUpdateOwner;
import prepared_rotate_update : PreparedRotateUpdateOwner;
import prepared_scale_update : PreparedScaleUpdateOwner;
import prepared_xfrm_update_tail : PreparedXfrmUpdateTailOwner;
import prepared_xfrm_update_edit_close : PreparedXfrmUpdateEditCloseOwner;
import prepared_xfrm_slot_poll : PreparedXfrmSlotPollOwner;
import prepared_xfrm_update_boundary : PreparedXfrmUpdateBoundaryOwner;
import prepared_xfrm_move_regrade : PreparedXfrmMoveRegradeOwner;
import prepared_inherited_noop : PreparedInheritedNoopOwner;
import prepared_xfrm_activation_session : PreparedXfrmActivationSessionOwner;
import prepared_stroke_extrude_activation : PreparedStrokeExtrudeActivationOwner;
import prepared_vertex_merge_activation : PreparedVertexMergeActivationOwner;
import prepared_poly_inset_activation : PreparedPolyInsetActivationOwner;
import prepared_poly_extrude_activation : PreparedPolyExtrudeActivationOwner;
import prepared_smooth_shift_activation : PreparedSmoothShiftActivationOwner;
import prepared_edge_bevel_activation : PreparedEdgeBevelActivationOwner;
import prepared_poly_bevel_activation : PreparedPolyBevelActivationOwner;
import prepared_vertex_bevel_activation : PreparedVertexBevelActivationOwner;
import prepared_vertex_extrude_activation : PreparedVertexExtrudeActivationOwner;
import prepared_edge_extrude_activation : PreparedEdgeExtrudeActivationOwner;
import prepared_edge_slice_activation : PreparedEdgeSliceActivationOwner;
import prepared_loop_slice_activation : PreparedLoopSliceActivationOwner;
import prepared_slice_activation : PreparedSliceActivationOwner;
import prepared_tack_activation : PreparedTackActivationOwner;
import prepared_command_wrapper_activation : PreparedCommandWrapperActivationOwner;
import prepared_bridge_activation : PreparedBridgeActivationOwner,
    PreparedBridgeDeactivateOwner;
import prepared_mirror_activation : PreparedMirrorActivationOwner,
    PreparedMirrorDeactivateOwner;
import prepared_edge_extend_tool_activation : PreparedEdgeExtendToolActivationOwner;
import prepared_topology_pen_activation : PreparedTopologyPenActivationOwner;
import prepared_topology_pen_update : PreparedTopologyPenUpdateOwner;
import prepared_topology_pen_deactivate : PreparedTopologyPenDeactivateOwner;
import prepared_array_param_update : PreparedArrayParamUpdateOwner;
import prepared_magnet_param_update : PreparedMagnetParamUpdateOwner;
import prepared_smooth_shift_param_update : PreparedSmoothShiftParamUpdateOwner;
import prepared_edge_bevel_param_update : PreparedEdgeBevelParamUpdateOwner;
import prepared_edge_extrude_param_update : PreparedEdgeExtrudeParamUpdateOwner;
import prepared_poly_bevel_param_update : PreparedPolyBevelParamUpdateOwner;
import prepared_poly_extrude_param_update : PreparedPolyExtrudeParamUpdateOwner;
import prepared_poly_inset_param_update : PreparedPolyInsetParamUpdateOwner;
import prepared_reduction_param_update : PreparedReductionParamUpdateOwner;
import prepared_vertex_merge_param_update : PreparedVertexMergeParamUpdateOwner;
import prepared_vertex_bevel_param_update : PreparedVertexBevelParamUpdateOwner;
import prepared_vertex_extrude_param_update : PreparedVertexExtrudeParamUpdateOwner;
import prepared_slice_deactivate : PreparedSliceDeactivateOwner;
import prepared_slice_param_update : PreparedSliceParamUpdateOwner;
import prepared_edge_slice_deactivate : PreparedEdgeSliceDeactivateOwner;
import prepared_edge_slice_param_update : PreparedEdgeSliceParamUpdateOwner;
import prepared_loop_slice_deactivate : PreparedLoopSliceDeactivateOwner;
import prepared_loop_slice_param_update : PreparedLoopSliceParamUpdateOwner;
import prepared_edge_extend_param_update : PreparedEdgeExtendParamUpdateOwner;
import prepared_edge_extend_deactivate : PreparedEdgeExtendDeactivateOwner;
import document : Layer;
import change_bus : PreparedDeliveryJournal, PreparedDeliverySpec, changeBus;
import change_bus : MeshEditScope;

private enum PreparedResourceKind : ubyte {
    HistoryInstall, NoHistoryInstall, MeshInstall, DeliveryInstall, GpuMeshDestroy,
    GpuUpload, ClickPointDestroy, BoxHandlerBatchDestroy
    , GpuCreate, SnapOverlayClear, BoxState, PenState, PrimitiveState, VertexState,
    ArraySessionState, CloneSessionState, MagnetSessionState, ReductionSessionState,
    RadialSweepProfileState, RadialSweepTransitionState, GestureCarrierMismatch,
    GpuCreateUpload, RadialArrayTransitionState, TransformActivationState,
    TransformProductActivationState, MoveUpdateState, RotateUpdateState,
    ScaleUpdateState, XfrmUpdateEditCloseState, XfrmSlotPollState,
    XfrmUpdateBoundaryState,
    XfrmMoveRegradeState,
    XfrmUpdateTailState,
    InheritedNoopState,
    XfrmActivationPreState, XfrmActivationPostState, StrokeExtrudeActivationState,
    VertexMergeActivationState, PolyInsetActivationState, PolyExtrudeActivationState,
    SmoothShiftActivationState, EdgeBevelActivationState,
    PolyBevelActivationState, VertexBevelActivationState,
    VertexExtrudeActivationState, EdgeExtrudeActivationState,
    EdgeSliceActivationState, LoopSliceActivationState, SliceActivationState,
    TackActivationState, CommandWrapperActivationState, BridgeActivationState,
    MirrorActivationState, EdgeExtendToolActivationPreState,
    EdgeExtendToolActivationPostState, TopologyPenActivationState,
    TopologyPenUpdateState, TopologyPenDeactivateState,
    MirrorDeactivateState, BridgeDeactivateState, ArrayParamUpdateState,
    MagnetParamUpdateState, SmoothShiftParamUpdateState,
    EdgeBevelParamUpdateState, EdgeExtrudeParamUpdateState,
    PolyBevelParamUpdateState, PolyExtrudeParamUpdateState,
    PolyInsetParamUpdateState, ReductionParamUpdateState,
    VertexMergeParamUpdateState, VertexBevelParamUpdateState,
    VertexExtrudeParamUpdateState, SliceDeactivateState, SliceParamUpdateState,
    EdgeSliceDeactivateState, EdgeSliceParamUpdateState, LoopSliceDeactivateState,
    LoopSliceParamUpdateState, EdgeExtendParamUpdateState, EdgeExtendDeactivateState
}
private struct PreparedResourceEntry {
    PreparedResourceKind kind;
    GpuResourceOwner gpuDestroy;
    GpuUploadOwner gpuUpload;
    GpuCreateOwner gpuCreate;
    GpuCreateUploadOwner gpuCreateUpload;
    PreparedRadialArrayTransitionOwner radialArrayTransition;
    PreparedTransformActivationOwner transformActivation;
    PreparedTransformProductActivationOwner transformProductActivation;
    PreparedMoveUpdateOwner moveUpdate;
    PreparedRotateUpdateOwner rotateUpdate;
    PreparedScaleUpdateOwner scaleUpdate;
    PreparedXfrmUpdateEditCloseOwner xfrmUpdateEditClose;
    PreparedXfrmSlotPollOwner xfrmSlotPoll;
    PreparedXfrmUpdateBoundaryOwner xfrmUpdateBoundary;
    PreparedXfrmMoveRegradeOwner xfrmMoveRegrade;
    PreparedXfrmUpdateTailOwner xfrmUpdateTail;
    PreparedInheritedNoopOwner inheritedNoop;
    PreparedXfrmActivationSessionOwner xfrmActivation;
    PreparedStrokeExtrudeActivationOwner strokeExtrudeActivation;
    PreparedVertexMergeActivationOwner vertexWeldActivation;
    PreparedPolyInsetActivationOwner polyInsetActivation;
    PreparedPolyExtrudeActivationOwner polyExtrudeActivation;
    PreparedSmoothShiftActivationOwner smoothShiftActivation;
    PreparedEdgeBevelActivationOwner edgeBevelActivation;
    PreparedPolyBevelActivationOwner polyBevelActivation;
    PreparedVertexBevelActivationOwner vertexBevelActivation;
    PreparedVertexExtrudeActivationOwner vertexExtrudeActivation;
    PreparedEdgeExtrudeActivationOwner edgeExtrudeActivation;
    PreparedEdgeSliceActivationOwner edgeSliceActivation;
    PreparedLoopSliceActivationOwner loopSliceActivation;
    PreparedSliceActivationOwner sliceActivation;
    PreparedTackActivationOwner tackActivation;
    PreparedCommandWrapperActivationOwner commandWrapperActivation;
    PreparedBridgeActivationOwner bridgeActivation;
    PreparedMirrorActivationOwner mirrorActivation;
    PreparedEdgeExtendToolActivationOwner edgeExtendToolActivation;
    PreparedTopologyPenActivationOwner topologyPenActivation;
    PreparedTopologyPenUpdateOwner topologyPenUpdate;
    PreparedTopologyPenDeactivateOwner topologyPenDeactivate;
    PreparedArrayParamUpdateOwner arrayParamUpdate;
    PreparedMagnetParamUpdateOwner magnetParamUpdate;
    PreparedSmoothShiftParamUpdateOwner smoothShiftParamUpdate;
    PreparedEdgeBevelParamUpdateOwner edgeBevelParamUpdate;
    PreparedEdgeExtrudeParamUpdateOwner edgeExtrudeParamUpdate;
    PreparedPolyBevelParamUpdateOwner polyBevelParamUpdate;
    PreparedPolyExtrudeParamUpdateOwner polyExtrudeParamUpdate;
    PreparedPolyInsetParamUpdateOwner polyInsetParamUpdate;
    PreparedReductionParamUpdateOwner reductionParamUpdate;
    PreparedVertexMergeParamUpdateOwner vertexMergeParamUpdate;
    PreparedVertexBevelParamUpdateOwner vertexBevelParamUpdate;
    PreparedVertexExtrudeParamUpdateOwner vertexExtrudeParamUpdate;
    PreparedSliceDeactivateOwner sliceDeactivate;
    PreparedSliceParamUpdateOwner sliceParamUpdate;
    PreparedEdgeSliceDeactivateOwner edgeSliceDeactivate;
    PreparedEdgeSliceParamUpdateOwner edgeSliceParamUpdate;
    PreparedLoopSliceDeactivateOwner loopSliceDeactivate;
    PreparedLoopSliceParamUpdateOwner loopSliceParamUpdate;
    PreparedEdgeExtendParamUpdateOwner edgeExtendParamUpdate;
    PreparedEdgeExtendDeactivateOwner edgeExtendDeactivate;
    PreparedMirrorDeactivateOwner mirrorDeactivate;
    PreparedBridgeDeactivateOwner bridgeDeactivate;
    ClickPointResourceOwner clickDestroy;
    BoxHandlerBatchResourceOwner boxHandlersDestroy;
    SnapOverlayOwner snapOverlay;
    PreparedPrivateStateOwner privateState;
    PreparedSelectionProfileOwner selectionProfile;
    PreparedRadialSweepTransitionOwner radialSweepTransition;
    Layer layerMesh;
    PreparedDeliveryJournal delivery;
}

/// One fallible prepare transaction jointly owns the detached history and
/// observer evolution. Tool producers receive this owner; they never discover
/// a global history, observer, or legacy delegate.
final class PreparedRecordContext {
private:
    CommandHistory history_;
    RecordObserverHub observers_;
    PreparedHistoryToken token_;
    ValidatedPreparedHistoryToken validated_;
    bool begun_, validated_Once;
    PreparedResourceEntry[] resources_;
    ulong resourceThread_, resourceContext_;
    bool historyMarker_;
    bool noHistoryMarker_;
    PreparedXfrmActivationSessionOwner xfrmLayoutOwner_;
    ubyte xfrmLayoutStage_; // 0=absent, 1=pre, 2=marker, 3=post
    version (unittest) {
        static bool failAfterResourceBegin_;
        ubyte[16] installTrace_;
        size_t installTraceLength_;
    }
public:
    this(CommandHistory history, RecordObserverHub observers) {
        history_ = history;
        observers_ = observers;
        if (history_ !is null) {
            token_ = history_.beginPrepared();
        }
        begun_ = true;
    }

    bool hasHistory() const nothrow @nogc { return history_ !is null; }
    bool ownsHistory(CommandHistory expected) const nothrow @nogc {
        return history_ is expected;
    }

    void setResourceIdentity(ulong threadIdentity, ulong contextIdentity)
                             nothrow @nogc {
        resourceThread_ = threadIdentity;
        resourceContext_ = contextIdentity;
    }

    /// Append the exact history position among resource effects. Resource
    /// transactions require exactly one marker; history-only transactions keep
    /// their historical direct install path.
    bool markHistoryInstall() {
        if (!begun_ || validated_Once || history_ is null || historyMarker_ || noHistoryMarker_ ||
            (xfrmLayoutStage_ != 0 && xfrmLayoutStage_ != 1)) return false;
        resources_.reserve(resources_.length + 1);
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.HistoryInstall;
        resources_ ~= e;
        historyMarker_ = true;
        if (xfrmLayoutStage_ == 1) xfrmLayoutStage_ = 2;
        return true;
    }

    bool markNoHistoryInstall() {
        if (!begun_ || validated_Once || historyMarker_ || noHistoryMarker_ ||
            (xfrmLayoutStage_ != 0 && xfrmLayoutStage_ != 1)) return false;
        resources_.reserve(1 + resources_.length);
        PreparedResourceEntry e; e.kind = PreparedResourceKind.NoHistoryInstall;
        resources_ ~= e; noHistoryMarker_ = true;
        if (xfrmLayoutStage_ == 1) xfrmLayoutStage_ = 2;
        return true;
    }

    bool prepareDestroy(GpuResourceOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(resources_.length + 1);
        if (!owner.beginEnlistedDestroy()) return false;
        scope(failure) owner.abortEnlisted();
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected resource enlist failure");
        resources_ ~= PreparedResourceEntry(
            PreparedResourceKind.GpuMeshDestroy, owner);
        return true;
    }

    bool prepareUpload(GpuUploadOwner owner, ref const Mesh mesh,
                       const uint[] edgeOrigin = null,
                       const uint[] vertOrigin = null,
                       const uint[] faceOrigin = null) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(resources_.length + 1);
        if (!owner.beginEnlistedUpload(mesh, edgeOrigin, vertOrigin,
                                       faceOrigin)) return false;
        scope(failure) owner.abortEnlisted();
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected resource enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.GpuUpload; e.gpuUpload = owner;
        resources_ ~= e;
        return true;
    }

    bool prepareDestroy(ClickPointResourceOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(resources_.length + 1);
        if (!owner.beginEnlistedDestroy()) return false;
        scope(failure) owner.abortEnlisted();
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected resource enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.ClickPointDestroy;
        e.clickDestroy = owner;
        resources_ ~= e;
        return true;
    }

    bool prepareDestroy(BoxHandlerBatchResourceOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(resources_.length + 1);
        if (!owner.beginEnlistedDestroy()) return false;
        scope(failure) owner.abortEnlisted();
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.BoxHandlerBatchDestroy;
        e.boxHandlersDestroy = owner; resources_ ~= e; return true;
    }

    bool prepareCreate(GpuCreateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.beginEnlistedCreate()) return false;
        scope(failure) { owner.abortEnlisted(); }
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected GPU create enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.GpuCreate;
        e.gpuCreate = owner; resources_ ~= e; return true;
    }

    bool prepareCreateUpload(GpuCreateUploadOwner owner, ref const Mesh mesh) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.beginEnlisted(mesh)) return false;
        scope(failure) { if (owner !is null) owner.abortEnlisted(); }
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected combined create-upload enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.GpuCreateUpload;
        e.gpuCreateUpload = owner; resources_ ~= e; return true;
    }

    bool prepareSnapClear(SnapOverlayOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.beginClear()) return false;
        scope(failure) owner.abortClear();
        PreparedResourceEntry e; e.kind = PreparedResourceKind.SnapOverlayClear;
        e.snapOverlay = owner; resources_ ~= e; return true;
    }

    bool preparePrivateState(PreparedPrivateStateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        PreparedResourceEntry e; e.privateState = owner;
        final switch (owner.kind) {
        case PreparedPrivateStateKind.Box: e.kind = PreparedResourceKind.BoxState; break;
        case PreparedPrivateStateKind.BoxDeactivate:
            e.kind = PreparedResourceKind.BoxState; break;
        case PreparedPrivateStateKind.Pen: e.kind = PreparedResourceKind.PenState; break;
        case PreparedPrivateStateKind.PenDeactivate:
            e.kind = PreparedResourceKind.PenState; break;
        case PreparedPrivateStateKind.PenParam:
            e.kind = PreparedResourceKind.PenState; break;
        case PreparedPrivateStateKind.Primitive: e.kind = PreparedResourceKind.PrimitiveState; break;
        case PreparedPrivateStateKind.PrimitiveDeactivate:
            e.kind = PreparedResourceKind.PrimitiveState; break;
        case PreparedPrivateStateKind.Vertex: e.kind = PreparedResourceKind.VertexState; break;
        case PreparedPrivateStateKind.ArraySession: e.kind = PreparedResourceKind.ArraySessionState; break;
        case PreparedPrivateStateKind.CloneSession: e.kind = PreparedResourceKind.CloneSessionState; break;
        case PreparedPrivateStateKind.MagnetSession: e.kind = PreparedResourceKind.MagnetSessionState; break;
        case PreparedPrivateStateKind.ReductionSession: e.kind = PreparedResourceKind.ReductionSessionState; break;
        }
        resources_ ~= e; return true;
    }

    bool prepareSelectionProfile(PreparedSelectionProfileOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected selection-profile enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.RadialSweepProfileState;
        e.selectionProfile = owner; resources_ ~= e; return true;
    }

    bool prepareXfrmActivationPre(PreparedXfrmActivationSessionOwner owner) {
        if (!begun_ || validated_Once || owner is null || xfrmLayoutStage_ != 0 ||
            historyMarker_ || noHistoryMarker_) return false;
        resources_.reserve(resources_.length + 1);
        if (!owner.beginPre()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Xfrm activation pre enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.XfrmActivationPreState;
        e.xfrmActivation = owner; resources_ ~= e;
        xfrmLayoutOwner_ = owner; xfrmLayoutStage_ = 1; return true;
    }

    bool prepareXfrmActivationPost(PreparedXfrmActivationSessionOwner owner) {
        if (!begun_ || validated_Once || owner is null ||
            xfrmLayoutStage_ != 2 || xfrmLayoutOwner_ !is owner ||
            resources_.length < 2 ||
            resources_[$ - 2].kind != PreparedResourceKind.XfrmActivationPreState ||
            resources_[$ - 2].xfrmActivation !is owner ||
            (resources_[$ - 1].kind != PreparedResourceKind.HistoryInstall &&
             resources_[$ - 1].kind != PreparedResourceKind.NoHistoryInstall)) return false;
        resources_.reserve(resources_.length + 1);
        if (!owner.beginPost()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Xfrm activation post enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.XfrmActivationPostState;
        e.xfrmActivation = owner; resources_ ~= e; xfrmLayoutStage_ = 3; return true;
    }

    bool prepareRadialSweepTransition(PreparedRadialSweepTransitionOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected radial-sweep transition enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.RadialSweepTransitionState;
        e.radialSweepTransition = owner; resources_ ~= e; return true;
    }

    bool prepareRadialArrayTransition(PreparedRadialArrayTransitionOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected radial-array transition enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.RadialArrayTransitionState;
        e.radialArrayTransition = owner; resources_ ~= e; return true;
    }

    bool prepareTransformActivation(PreparedTransformActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected transform activation enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.TransformActivationState;
        e.transformActivation = owner; resources_ ~= e; return true;
    }
    bool prepareTransformProductActivation(PreparedTransformProductActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected transform product activation enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.TransformProductActivationState;
        e.transformProductActivation = owner; resources_ ~= e; return true;
    }
    bool prepareMoveUpdate(PreparedMoveUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected move update enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.MoveUpdateState;
        e.moveUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareRotateUpdate(PreparedRotateUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected rotate update enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.RotateUpdateState;
        e.rotateUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareScaleUpdate(PreparedScaleUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected scale update enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.ScaleUpdateState;
        e.scaleUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareXfrmUpdateTail(PreparedXfrmUpdateTailOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Xfrm update tail enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.XfrmUpdateTailState;
        e.xfrmUpdateTail = owner; resources_ ~= e; return true;
    }
    bool prepareXfrmUpdateEditClose(PreparedXfrmUpdateEditCloseOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Xfrm update edit-close enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.XfrmUpdateEditCloseState;
        e.xfrmUpdateEditClose = owner; resources_ ~= e; return true;
    }
    bool prepareXfrmSlotPoll(PreparedXfrmSlotPollOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Xfrm slot-poll enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.XfrmSlotPollState;
        e.xfrmSlotPoll = owner; resources_ ~= e; return true;
    }
    bool prepareXfrmUpdateBoundary(PreparedXfrmUpdateBoundaryOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Xfrm update boundary enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.XfrmUpdateBoundaryState;
        e.xfrmUpdateBoundary = owner; resources_ ~= e; return true;
    }
    bool prepareXfrmMoveRegrade(PreparedXfrmMoveRegradeOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version (unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Xfrm Move re-grade enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.XfrmMoveRegradeState;
        e.xfrmMoveRegrade = owner; resources_ ~= e; return true;
    }
    bool prepareStrokeExtrudeActivation(PreparedStrokeExtrudeActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected StrokeExtrude activation enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.StrokeExtrudeActivationState;
        e.strokeExtrudeActivation = owner; resources_ ~= e; return true;
    }
    bool prepareVertexMergeActivation(PreparedVertexMergeActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected VertexMerge activation enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.VertexMergeActivationState;
        e.vertexWeldActivation = owner; resources_ ~= e; return true;
    }
    bool preparePolyInsetActivation(PreparedPolyInsetActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected PolyInset activation enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.PolyInsetActivationState;
        e.polyInsetActivation = owner; resources_ ~= e; return true;
    }
    bool preparePolyExtrudeActivation(PreparedPolyExtrudeActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected PolyExtrude activation enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.PolyExtrudeActivationState;
        e.polyExtrudeActivation = owner; resources_ ~= e; return true;
    }
    bool prepareSmoothShiftActivation(PreparedSmoothShiftActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected SmoothShift activation enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.SmoothShiftActivationState;
        e.smoothShiftActivation = owner; resources_ ~= e; return true;
    }
    bool prepareEdgeBevelActivation(PreparedEdgeBevelActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected EdgeBevel activation enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.EdgeBevelActivationState;
        e.edgeBevelActivation = owner; resources_ ~= e; return true;
    }
    bool preparePolyBevelActivation(PreparedPolyBevelActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected PolyBevel activation enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.PolyBevelActivationState;
        e.polyBevelActivation = owner; resources_ ~= e; return true;
    }
    bool prepareVertexBevelActivation(PreparedVertexBevelActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected VertexBevel activation enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.VertexBevelActivationState;
        e.vertexBevelActivation = owner; resources_ ~= e; return true;
    }
    bool prepareVertexExtrudeActivation(PreparedVertexExtrudeActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected VertexExtrude activation enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.VertexExtrudeActivationState;
        e.vertexExtrudeActivation = owner; resources_ ~= e; return true;
    }
    bool prepareEdgeExtrudeActivation(PreparedEdgeExtrudeActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected EdgeExtrude activation enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.EdgeExtrudeActivationState;
        e.edgeExtrudeActivation = owner; resources_ ~= e; return true;
    }
    bool prepareEdgeSliceActivation(PreparedEdgeSliceActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected EdgeSlice activation enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.EdgeSliceActivationState;
        e.edgeSliceActivation = owner; resources_ ~= e; return true;
    }
    bool prepareLoopSliceActivation(PreparedLoopSliceActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected LoopSlice activation enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.LoopSliceActivationState;
        e.loopSliceActivation = owner; resources_ ~= e; return true;
    }
    bool prepareSliceActivation(PreparedSliceActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Slice activation enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.SliceActivationState;
        e.sliceActivation = owner; resources_ ~= e; return true;
    }
    bool prepareTackActivation(PreparedTackActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Tack activation enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.TackActivationState;
        e.tackActivation = owner; resources_ ~= e; return true;
    }
    bool prepareCommandWrapperActivation(PreparedCommandWrapperActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected CommandWrapper activation enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.CommandWrapperActivationState;
        e.commandWrapperActivation = owner; resources_ ~= e; return true;
    }
    bool prepareBridgeActivation(PreparedBridgeActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Bridge activation enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.BridgeActivationState;
        e.bridgeActivation = owner; resources_ ~= e; return true;
    }
    bool prepareBridgeDeactivate(PreparedBridgeDeactivateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Bridge deactivation enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.BridgeDeactivateState;
        e.bridgeDeactivate = owner; resources_ ~= e; return true;
    }
    bool prepareMirrorActivation(PreparedMirrorActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Mirror activation enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.MirrorActivationState;
        e.mirrorActivation = owner; resources_ ~= e; return true;
    }
    bool prepareMirrorDeactivate(PreparedMirrorDeactivateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Mirror deactivation enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.MirrorDeactivateState;
        e.mirrorDeactivate = owner; resources_ ~= e; return true;
    }
    bool prepareEdgeExtendToolActivationPre(
            PreparedEdgeExtendToolActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null || historyMarker_ ||
            noHistoryMarker_) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.beginPre()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected EdgeExtend activation pre enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.EdgeExtendToolActivationPreState;
        e.edgeExtendToolActivation = owner; resources_ ~= e; return true;
    }
    bool prepareEdgeExtendToolActivationPost(
            PreparedEdgeExtendToolActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null ||
            xfrmLayoutStage_ != 3 || resources_.length < 4 ||
            resources_[$ - 1].kind != PreparedResourceKind.XfrmActivationPostState)
            return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.beginPost()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected EdgeExtend activation post enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.EdgeExtendToolActivationPostState;
        e.edgeExtendToolActivation = owner; resources_ ~= e; return true;
    }
    bool prepareTopologyPenActivation(PreparedTopologyPenActivationOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected TopologyPen activation enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.TopologyPenActivationState;
        e.topologyPenActivation = owner; resources_ ~= e; return true;
    }
    bool prepareTopologyPenUpdate(PreparedTopologyPenUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected TopologyPen update enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.TopologyPenUpdateState;
        e.topologyPenUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareTopologyPenDeactivate(PreparedTopologyPenDeactivateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected TopologyPen deactivate enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.TopologyPenDeactivateState;
        e.topologyPenDeactivate = owner; resources_ ~= e; return true;
    }
    bool prepareArrayParamUpdate(PreparedArrayParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Array parameter enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.ArrayParamUpdateState;
        e.arrayParamUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareMagnetParamUpdate(PreparedMagnetParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Magnet parameter enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.MagnetParamUpdateState;
        e.magnetParamUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareSmoothShiftParamUpdate(PreparedSmoothShiftParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Smooth Shift parameter enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.SmoothShiftParamUpdateState;
        e.smoothShiftParamUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareEdgeBevelParamUpdate(PreparedEdgeBevelParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Edge Bevel parameter enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.EdgeBevelParamUpdateState;
        e.edgeBevelParamUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareEdgeExtrudeParamUpdate(PreparedEdgeExtrudeParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Edge Extrude parameter enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.EdgeExtrudeParamUpdateState;
        e.edgeExtrudeParamUpdate = owner; resources_ ~= e; return true;
    }
    bool preparePolyBevelParamUpdate(PreparedPolyBevelParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Poly Bevel parameter enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.PolyBevelParamUpdateState;
        e.polyBevelParamUpdate = owner; resources_ ~= e; return true;
    }
    bool preparePolyExtrudeParamUpdate(PreparedPolyExtrudeParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Poly Extrude parameter enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.PolyExtrudeParamUpdateState;
        e.polyExtrudeParamUpdate = owner; resources_ ~= e; return true;
    }
    bool preparePolyInsetParamUpdate(PreparedPolyInsetParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Poly Inset parameter enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.PolyInsetParamUpdateState;
        e.polyInsetParamUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareReductionParamUpdate(PreparedReductionParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Reduction parameter enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.ReductionParamUpdateState;
        e.reductionParamUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareVertexMergeParamUpdate(PreparedVertexMergeParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Vertex Merge parameter enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.VertexMergeParamUpdateState;
        e.vertexMergeParamUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareVertexBevelParamUpdate(PreparedVertexBevelParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Vertex Bevel parameter enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.VertexBevelParamUpdateState;
        e.vertexBevelParamUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareVertexExtrudeParamUpdate(
            PreparedVertexExtrudeParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Vertex Extrude parameter enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.VertexExtrudeParamUpdateState;
        e.vertexExtrudeParamUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareSliceDeactivate(PreparedSliceDeactivateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Slice deactivate enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.SliceDeactivateState;
        e.sliceDeactivate = owner; resources_ ~= e; return true;
    }
    bool prepareSliceParamUpdate(PreparedSliceParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Slice param enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.SliceParamUpdateState;
        e.sliceParamUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareEdgeSliceDeactivate(PreparedEdgeSliceDeactivateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Edge Slice deactivate enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.EdgeSliceDeactivateState;
        e.edgeSliceDeactivate = owner; resources_ ~= e; return true;
    }
    bool prepareEdgeSliceParamUpdate(PreparedEdgeSliceParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Edge Slice parameter enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.EdgeSliceParamUpdateState;
        e.edgeSliceParamUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareLoopSliceDeactivate(PreparedLoopSliceDeactivateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Loop Slice deactivate enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.LoopSliceDeactivateState;
        e.loopSliceDeactivate = owner; resources_ ~= e; return true;
    }
    bool prepareLoopSliceParamUpdate(PreparedLoopSliceParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Loop Slice parameter enlist failure");
        PreparedResourceEntry e;
        e.kind = PreparedResourceKind.LoopSliceParamUpdateState;
        e.loopSliceParamUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareEdgeExtendParamUpdate(PreparedEdgeExtendParamUpdateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Edge Extend parameter enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.EdgeExtendParamUpdateState;
        e.edgeExtendParamUpdate = owner; resources_ ~= e; return true;
    }
    bool prepareEdgeExtendDeactivate(PreparedEdgeExtendDeactivateOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected Edge Extend deactivate enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.EdgeExtendDeactivateState;
        e.edgeExtendDeactivate = owner; resources_ ~= e; return true;
    }
    bool prepareInheritedNoop(PreparedInheritedNoopOwner owner) {
        if (!begun_ || validated_Once || owner is null) return false;
        resources_.reserve(1 + resources_.length);
        if (!owner.begin()) return false;
        scope(failure) owner.abort();
        version(unittest) if (failAfterResourceBegin_)
            throw new Exception("injected inherited-noop enlist failure");
        PreparedResourceEntry e; e.kind = PreparedResourceKind.InheritedNoopState;
        e.inheritedNoop = owner; resources_ ~= e; return true;
    }

    bool prepareGestureCarrierMismatch() {
        if (!begun_ || validated_Once) return false;
        resources_.reserve(1 + resources_.length);
        PreparedResourceEntry e; e.kind = PreparedResourceKind.GestureCarrierMismatch;
        resources_ ~= e; return true;
    }

    bool prepareMeshImageCommit(Layer layer, ref const Mesh image, uint flags) {
        if (!begun_ || validated_Once || layer is null || flags == 0) return false;
        resources_.reserve(resources_.length + 2);
        if (!layer.beginEnlistedMesh()) return false;
        scope(failure) { layer.abortEnlistedMesh(); invalidateTransaction(); }
        if (!layer.replaceEnlistedShadow(image)) {
            layer.abortEnlistedMesh(); invalidateTransaction(); return false;
        }
        {
            auto shadowScope = layer.beginEnlistedShadowMutation();
            layer.enlistedShadow().commitChange(flags);
            shadowScope.close();
        }
        auto spec = layer.drainEnlistedDelivery();
        auto delivery = PreparedDeliveryJournal.prepare([spec]);
        PreparedResourceEntry meshEntry; meshEntry.kind = PreparedResourceKind.MeshInstall;
        meshEntry.layerMesh = layer; resources_ ~= meshEntry;
        PreparedResourceEntry deliveryEntry; deliveryEntry.kind = PreparedResourceKind.DeliveryInstall;
        deliveryEntry.delivery = delivery; resources_ ~= deliveryEntry;
        return true;
    }

    /// Adopt an image whose detached kernel already performed the exact
    /// legacy commitChange. Its pending delivery was drained by that kernel;
    /// do not stamp or derive the image a second time here.
    bool prepareStampedMeshImage(Layer layer, ref const Mesh image,
                                 uint flags, uint domains) {
        if (!begun_ || validated_Once || layer is null || flags == 0) return false;
        resources_.reserve(resources_.length + 2);
        if (!layer.beginEnlistedMesh()) return false;
        scope(failure) { layer.abortEnlistedMesh(); invalidateTransaction(); }
        if (!layer.replaceEnlistedShadow(image)) {
            layer.abortEnlistedMesh(); invalidateTransaction(); return false;
        }
        auto delivery = PreparedDeliveryJournal.prepare(
            [layer.enlistedDeliveryForStampedImage(flags, domains)]);
        PreparedResourceEntry meshEntry; meshEntry.kind = PreparedResourceKind.MeshInstall;
        meshEntry.layerMesh = layer; resources_ ~= meshEntry;
        PreparedResourceEntry deliveryEntry; deliveryEntry.kind = PreparedResourceKind.DeliveryInstall;
        deliveryEntry.delivery = delivery; resources_ ~= deliveryEntry;
        return true;
    }

    bool preparePositionCommit(Layer layer) {
        if (!begun_ || validated_Once || layer is null) return false;
        resources_.reserve(resources_.length + 2);
        if (!layer.beginEnlistedMesh()) return false;
        scope(failure) {
            layer.abortEnlistedMesh();
            invalidateTransaction();
        }
        {
            auto shadowScope = layer.beginEnlistedShadowMutation();
            layer.enlistedShadow().commitChange(MeshEditScope.Position);
            shadowScope.close();
        }
        auto spec = layer.drainEnlistedDelivery();
        auto delivery = PreparedDeliveryJournal.prepare([spec]);
        PreparedResourceEntry meshEntry;
        meshEntry.kind = PreparedResourceKind.MeshInstall;
        meshEntry.layerMesh = layer;
        resources_ ~= meshEntry;
        PreparedResourceEntry deliveryEntry;
        deliveryEntry.kind = PreparedResourceKind.DeliveryInstall;
        deliveryEntry.delivery = delivery;
        resources_ ~= deliveryEntry;
        return true;
    }

    /// Append the suppress-cage Position delivery to a mesh image already
    /// enlisted by an earlier detached kernel in this transaction. The mesh
    /// row remains unique; only the second legacy delivery is appended here.
    bool preparePositionCommitOnEnlisted(Layer layer) {
        if (!begun_ || validated_Once || layer is null ||
            !layer.hasEnlistedMesh()) return false;
        // This is the second half of the same mesh/delivery product whose Mesh
        // row was appended by prepareStampedMeshImage earlier.
        resources_.reserve(resources_.length + 2);
        scope(failure) {
            invalidateTransaction();
            layer.abortEnlistedMesh();
        }
        {
            auto shadowScope = layer.beginEnlistedShadowMutation();
            layer.enlistedShadow().commitChange(MeshEditScope.Position);
            shadowScope.close();
        }
        auto delivery = PreparedDeliveryJournal.prepare(
            [layer.drainEnlistedDelivery()]);
        PreparedResourceEntry deliveryEntry;
        deliveryEntry.kind = PreparedResourceKind.DeliveryInstall;
        deliveryEntry.delivery = delivery;
        resources_ ~= deliveryEntry;
        return true;
    }

    PreparedHistoryResult prepare(Command cmd, PreparedHistoryKind kind,
                                  ulong runId = 0,
                                  string preparedTraceJson = null) {
        if (!begun_ || validated_Once || history_ is null) return PreparedHistoryResult.init;
        return history_.prepareRecord(token_, cmd, kind, runId,
                                      observers_, preparedTraceJson);
    }

    PreparedHistoryResult consolidate(ulong runId) {
        if (!begun_ || validated_Once || history_ is null) return PreparedHistoryResult.init;
        return history_.prepareConsolidate(token_, runId);
    }

    PreparedHistoryResult prepareInvalidateRedo() {
        if (!begun_ || validated_Once || history_ is null)
            return PreparedHistoryResult.init;
        return history_.prepareInvalidateRedo(token_);
    }

    ulong nextRun() {
        if (!begun_ || validated_Once || history_ is null) return 0;
        return history_.prepareNextRun(token_);
    }

    bool validate() nothrow @nogc {
        if (!begun_ || validated_Once) return false;
        if (xfrmLayoutStage_ != 0 && xfrmLayoutStage_ != 3) {
            invalidateTransaction();
            return false;
        }
        if (resources_.length > 0 && !historyMarker_) {
            if (!noHistoryMarker_) {
                invalidateTransaction();
                return false;
            }
        }
        foreach (ref e; resources_) {
            bool ok;
            final switch (e.kind) {
            case PreparedResourceKind.HistoryInstall: ok = true; break;
            case PreparedResourceKind.NoHistoryInstall: ok = true; break;
            case PreparedResourceKind.MeshInstall:
                ok = e.layerMesh.validateEnlistedMesh(); break;
            case PreparedResourceKind.DeliveryInstall:
                ok = e.delivery !is null && e.delivery.validate(); break;
            case PreparedResourceKind.GpuMeshDestroy:
                ok = e.gpuDestroy.validateEnlisted(resourceThread_, resourceContext_); break;
            case PreparedResourceKind.GpuUpload:
                ok = e.gpuUpload.validateEnlisted(resourceThread_, resourceContext_); break;
            case PreparedResourceKind.ClickPointDestroy:
                ok = e.clickDestroy.validateEnlisted(resourceThread_, resourceContext_); break;
            case PreparedResourceKind.BoxHandlerBatchDestroy:
                ok = e.boxHandlersDestroy.validateEnlisted(
                    resourceThread_, resourceContext_); break;
            case PreparedResourceKind.GpuCreate:
                ok = e.gpuCreate.validateEnlisted(resourceThread_, resourceContext_); break;
            case PreparedResourceKind.SnapOverlayClear:
                ok = e.snapOverlay.validateClear(); break;
            case PreparedResourceKind.BoxState:
            case PreparedResourceKind.PenState:
            case PreparedResourceKind.PrimitiveState:
            case PreparedResourceKind.VertexState:
            case PreparedResourceKind.ArraySessionState:
            case PreparedResourceKind.CloneSessionState:
            case PreparedResourceKind.MagnetSessionState:
            case PreparedResourceKind.ReductionSessionState:
                ok = e.privateState.validate(); break;
            case PreparedResourceKind.RadialSweepProfileState:
                ok = e.selectionProfile !is null && e.selectionProfile.validate(); break;
            case PreparedResourceKind.RadialSweepTransitionState:
                ok = e.radialSweepTransition !is null && e.radialSweepTransition.validate(); break;
            case PreparedResourceKind.GestureCarrierMismatch: ok = true; break;
            case PreparedResourceKind.GpuCreateUpload:
                ok = e.gpuCreateUpload !is null &&
                    e.gpuCreateUpload.validateEnlisted(resourceThread_, resourceContext_); break;
            case PreparedResourceKind.RadialArrayTransitionState:
                ok = e.radialArrayTransition !is null &&
                    e.radialArrayTransition.validate(); break;
            case PreparedResourceKind.TransformActivationState:
                ok = e.transformActivation !is null &&
                    e.transformActivation.validate(); break;
            case PreparedResourceKind.TransformProductActivationState:
                ok = e.transformProductActivation !is null &&
                    e.transformProductActivation.validate(); break;
            case PreparedResourceKind.MoveUpdateState:
                ok = e.moveUpdate !is null && e.moveUpdate.validate(); break;
            case PreparedResourceKind.RotateUpdateState:
                ok = e.rotateUpdate !is null && e.rotateUpdate.validate(); break;
            case PreparedResourceKind.ScaleUpdateState:
                ok = e.scaleUpdate !is null && e.scaleUpdate.validate(); break;
            case PreparedResourceKind.XfrmUpdateTailState:
                ok = e.xfrmUpdateTail !is null && e.xfrmUpdateTail.validate(); break;
            case PreparedResourceKind.XfrmUpdateEditCloseState:
                ok = e.xfrmUpdateEditClose !is null &&
                    e.xfrmUpdateEditClose.validate(); break;
            case PreparedResourceKind.XfrmSlotPollState:
                ok = e.xfrmSlotPoll !is null && e.xfrmSlotPoll.validate(); break;
            case PreparedResourceKind.XfrmUpdateBoundaryState:
                ok = e.xfrmUpdateBoundary !is null &&
                    e.xfrmUpdateBoundary.validate(); break;
            case PreparedResourceKind.XfrmMoveRegradeState:
                ok = e.xfrmMoveRegrade !is null &&
                    e.xfrmMoveRegrade.validate(); break;
            case PreparedResourceKind.InheritedNoopState:
                ok = e.inheritedNoop !is null && e.inheritedNoop.validate(); break;
            case PreparedResourceKind.XfrmActivationPreState:
                ok = e.xfrmActivation !is null &&
                    e.xfrmActivation.validatePre(); break;
            case PreparedResourceKind.XfrmActivationPostState:
                ok = e.xfrmActivation !is null &&
                    e.xfrmActivation.validatePost(); break;
            case PreparedResourceKind.StrokeExtrudeActivationState:
                ok = e.strokeExtrudeActivation !is null &&
                    e.strokeExtrudeActivation.validate(); break;
            case PreparedResourceKind.VertexMergeActivationState:
                ok = e.vertexWeldActivation !is null &&
                    e.vertexWeldActivation.validate(); break;
            case PreparedResourceKind.PolyInsetActivationState:
                ok = e.polyInsetActivation !is null &&
                    e.polyInsetActivation.validate(); break;
            case PreparedResourceKind.PolyExtrudeActivationState:
                ok = e.polyExtrudeActivation !is null &&
                    e.polyExtrudeActivation.validate(); break;
            case PreparedResourceKind.SmoothShiftActivationState:
                ok = e.smoothShiftActivation !is null &&
                    e.smoothShiftActivation.validate(); break;
            case PreparedResourceKind.EdgeBevelActivationState:
                ok = e.edgeBevelActivation !is null &&
                    e.edgeBevelActivation.validate(); break;
            case PreparedResourceKind.PolyBevelActivationState:
                ok = e.polyBevelActivation !is null &&
                    e.polyBevelActivation.validate(); break;
            case PreparedResourceKind.VertexBevelActivationState:
                ok = e.vertexBevelActivation !is null &&
                    e.vertexBevelActivation.validate(); break;
            case PreparedResourceKind.VertexExtrudeActivationState:
                ok = e.vertexExtrudeActivation !is null &&
                    e.vertexExtrudeActivation.validate(); break;
            case PreparedResourceKind.EdgeExtrudeActivationState:
                ok = e.edgeExtrudeActivation !is null &&
                    e.edgeExtrudeActivation.validate(); break;
            case PreparedResourceKind.EdgeSliceActivationState:
                ok = e.edgeSliceActivation !is null &&
                    e.edgeSliceActivation.validate(); break;
            case PreparedResourceKind.LoopSliceActivationState:
                ok = e.loopSliceActivation !is null &&
                    e.loopSliceActivation.validate(); break;
            case PreparedResourceKind.SliceActivationState:
                ok = e.sliceActivation !is null &&
                    e.sliceActivation.validate(); break;
            case PreparedResourceKind.TackActivationState:
                ok = e.tackActivation !is null &&
                    e.tackActivation.validate(); break;
            case PreparedResourceKind.CommandWrapperActivationState:
                ok = e.commandWrapperActivation !is null &&
                    e.commandWrapperActivation.validate(); break;
            case PreparedResourceKind.BridgeActivationState:
                ok = e.bridgeActivation !is null && e.bridgeActivation.validate(); break;
            case PreparedResourceKind.MirrorActivationState:
                ok = e.mirrorActivation !is null && e.mirrorActivation.validate(); break;
            case PreparedResourceKind.EdgeExtendToolActivationPreState:
                ok = e.edgeExtendToolActivation !is null &&
                    e.edgeExtendToolActivation.validatePre(); break;
            case PreparedResourceKind.EdgeExtendToolActivationPostState:
                ok = e.edgeExtendToolActivation !is null &&
                    e.edgeExtendToolActivation.validatePost(); break;
            case PreparedResourceKind.TopologyPenActivationState:
                ok = e.topologyPenActivation !is null &&
                    e.topologyPenActivation.validate(); break;
            case PreparedResourceKind.TopologyPenUpdateState:
                ok = e.topologyPenUpdate !is null &&
                    e.topologyPenUpdate.validate(); break;
            case PreparedResourceKind.TopologyPenDeactivateState:
                ok = e.topologyPenDeactivate !is null &&
                    e.topologyPenDeactivate.validate(); break;
            case PreparedResourceKind.ArrayParamUpdateState:
                ok = e.arrayParamUpdate !is null &&
                    e.arrayParamUpdate.validate(); break;
            case PreparedResourceKind.MagnetParamUpdateState:
                ok = e.magnetParamUpdate !is null &&
                    e.magnetParamUpdate.validate(); break;
            case PreparedResourceKind.SmoothShiftParamUpdateState:
                ok = e.smoothShiftParamUpdate !is null &&
                    e.smoothShiftParamUpdate.validate(); break;
            case PreparedResourceKind.EdgeBevelParamUpdateState:
                ok = e.edgeBevelParamUpdate !is null &&
                    e.edgeBevelParamUpdate.validate(); break;
            case PreparedResourceKind.EdgeExtrudeParamUpdateState:
                ok = e.edgeExtrudeParamUpdate !is null &&
                    e.edgeExtrudeParamUpdate.validate(); break;
            case PreparedResourceKind.PolyBevelParamUpdateState:
                ok = e.polyBevelParamUpdate !is null &&
                    e.polyBevelParamUpdate.validate(); break;
            case PreparedResourceKind.PolyExtrudeParamUpdateState:
                ok = e.polyExtrudeParamUpdate !is null &&
                    e.polyExtrudeParamUpdate.validate(); break;
            case PreparedResourceKind.PolyInsetParamUpdateState:
                ok = e.polyInsetParamUpdate !is null &&
                    e.polyInsetParamUpdate.validate(); break;
            case PreparedResourceKind.ReductionParamUpdateState:
                ok = e.reductionParamUpdate !is null &&
                    e.reductionParamUpdate.validate(); break;
            case PreparedResourceKind.VertexMergeParamUpdateState:
                ok = e.vertexMergeParamUpdate !is null &&
                    e.vertexMergeParamUpdate.validate(); break;
            case PreparedResourceKind.VertexBevelParamUpdateState:
                ok = e.vertexBevelParamUpdate !is null &&
                    e.vertexBevelParamUpdate.validate(); break;
            case PreparedResourceKind.VertexExtrudeParamUpdateState:
                ok = e.vertexExtrudeParamUpdate !is null &&
                    e.vertexExtrudeParamUpdate.validate(); break;
            case PreparedResourceKind.SliceDeactivateState:
                ok = e.sliceDeactivate !is null &&
                    e.sliceDeactivate.validate(); break;
            case PreparedResourceKind.SliceParamUpdateState:
                ok = e.sliceParamUpdate !is null &&
                    e.sliceParamUpdate.validate(); break;
            case PreparedResourceKind.EdgeSliceDeactivateState:
                ok = e.edgeSliceDeactivate !is null &&
                    e.edgeSliceDeactivate.validate(); break;
            case PreparedResourceKind.EdgeSliceParamUpdateState:
                ok = e.edgeSliceParamUpdate !is null &&
                    e.edgeSliceParamUpdate.validate(); break;
            case PreparedResourceKind.LoopSliceDeactivateState:
                ok = e.loopSliceDeactivate !is null &&
                    e.loopSliceDeactivate.validate(); break;
            case PreparedResourceKind.LoopSliceParamUpdateState:
                ok = e.loopSliceParamUpdate !is null &&
                    e.loopSliceParamUpdate.validate(); break;
            case PreparedResourceKind.EdgeExtendParamUpdateState:
                ok = e.edgeExtendParamUpdate !is null &&
                    e.edgeExtendParamUpdate.validate(); break;
            case PreparedResourceKind.EdgeExtendDeactivateState:
                ok = e.edgeExtendDeactivate !is null &&
                    e.edgeExtendDeactivate.validate(); break;
            case PreparedResourceKind.MirrorDeactivateState:
                ok = e.mirrorDeactivate !is null &&
                    e.mirrorDeactivate.validate(); break;
            case PreparedResourceKind.BridgeDeactivateState:
                ok = e.bridgeDeactivate !is null &&
                    e.bridgeDeactivate.validate(); break;
            }
            if (!ok) { invalidateTransaction(); return false; }
        }
        if (noHistoryMarker_) validated_Once = true;
        else {
            validated_ = history_.validatesPreparedToken(token_, observers_);
            validated_Once = validated_.valid;
        }
        if (!validated_Once) invalidateTransaction();
        return validated_Once;
    }

    void install() nothrow {
        if (!validated_Once) return;
        bool installedHistory;
        foreach (ref e; resources_) final switch (e.kind) {
        case PreparedResourceKind.HistoryInstall:
            history_.installPreparedToken(validated_); installedHistory = true;
            version (unittest) installTrace_[installTraceLength_++] = 1;
            break;
        case PreparedResourceKind.NoHistoryInstall:
            if (history_ !is null) history_.discardPreparedToken(token_);
            installedHistory = true;
            version (unittest) installTrace_[installTraceLength_++] = 8;
            break;
        case PreparedResourceKind.MeshInstall:
            e.layerMesh.installEnlistedMesh();
            version (unittest) installTrace_[installTraceLength_++] = 3;
            break;
        case PreparedResourceKind.DeliveryInstall:
            e.delivery.replay(changeBus);
            version (unittest) installTrace_[installTraceLength_++] = 4;
            break;
        case PreparedResourceKind.GpuMeshDestroy:
            e.gpuDestroy.installEnlisted();
            version (unittest) installTrace_[installTraceLength_++] = 2;
            break;
        case PreparedResourceKind.GpuUpload:
            e.gpuUpload.installEnlisted();
            version (unittest) installTrace_[installTraceLength_++] = 2;
            break;
        case PreparedResourceKind.ClickPointDestroy:
            e.clickDestroy.installEnlisted();
            version (unittest) installTrace_[installTraceLength_++] = 2;
            break;
        case PreparedResourceKind.BoxHandlerBatchDestroy:
            e.boxHandlersDestroy.installEnlisted();
            version (unittest) installTrace_[installTraceLength_++] = 2;
            break;
        case PreparedResourceKind.GpuCreate:
            e.gpuCreate.installEnlisted();
            version (unittest) installTrace_[installTraceLength_++] = 5;
            break;
        case PreparedResourceKind.SnapOverlayClear:
            e.snapOverlay.installClear();
            version (unittest) installTrace_[installTraceLength_++] = 6;
            break;
        case PreparedResourceKind.BoxState:
        case PreparedResourceKind.PenState:
        case PreparedResourceKind.PrimitiveState:
        case PreparedResourceKind.VertexState:
        case PreparedResourceKind.ArraySessionState:
        case PreparedResourceKind.CloneSessionState:
        case PreparedResourceKind.MagnetSessionState:
        case PreparedResourceKind.ReductionSessionState:
            e.privateState.install();
            version (unittest) installTrace_[installTraceLength_++] = 7;
            break;
        case PreparedResourceKind.RadialSweepProfileState:
            e.selectionProfile.install();
            version (unittest) installTrace_[installTraceLength_++] = 9;
            break;
        case PreparedResourceKind.RadialSweepTransitionState:
            e.radialSweepTransition.install();
            version (unittest) installTrace_[installTraceLength_++] = 10;
            break;
        case PreparedResourceKind.GestureCarrierMismatch:
            ++changeBus.gestureCarrierMismatch;
            version (unittest) installTrace_[installTraceLength_++] = 11;
            break;
        case PreparedResourceKind.GpuCreateUpload:
            e.gpuCreateUpload.installEnlisted();
            version(unittest) installTrace_[installTraceLength_++] = 12;
            break;
        case PreparedResourceKind.RadialArrayTransitionState:
            e.radialArrayTransition.install();
            version(unittest) installTrace_[installTraceLength_++] = 13;
            break;
        case PreparedResourceKind.TransformActivationState:
            e.transformActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 14;
            break;
        case PreparedResourceKind.TransformProductActivationState:
            e.transformProductActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 15;
            break;
        case PreparedResourceKind.MoveUpdateState:
            e.moveUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 16;
            break;
        case PreparedResourceKind.RotateUpdateState:
            e.rotateUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 56;
            break;
        case PreparedResourceKind.ScaleUpdateState:
            e.scaleUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 57;
            break;
        case PreparedResourceKind.XfrmUpdateTailState:
            e.xfrmUpdateTail.install();
            version(unittest) installTrace_[installTraceLength_++] = 59;
            break;
        case PreparedResourceKind.XfrmUpdateEditCloseState:
            e.xfrmUpdateEditClose.install();
            version(unittest) installTrace_[installTraceLength_++] = 60;
            break;
        case PreparedResourceKind.XfrmSlotPollState:
            e.xfrmSlotPoll.install();
            version(unittest) installTrace_[installTraceLength_++] = 61;
            break;
        case PreparedResourceKind.XfrmUpdateBoundaryState:
            e.xfrmUpdateBoundary.install();
            version(unittest) installTrace_[installTraceLength_++] = 62;
            break;
        case PreparedResourceKind.XfrmMoveRegradeState:
            e.xfrmMoveRegrade.install();
            version(unittest) installTrace_[installTraceLength_++] = 63;
            break;
        case PreparedResourceKind.InheritedNoopState:
            e.inheritedNoop.install();
            version(unittest) installTrace_[installTraceLength_++] = 17;
            break;
        case PreparedResourceKind.XfrmActivationPreState:
            e.xfrmActivation.installPre();
            version(unittest) installTrace_[installTraceLength_++] = 18;
            break;
        case PreparedResourceKind.XfrmActivationPostState:
            e.xfrmActivation.installPost();
            version(unittest) installTrace_[installTraceLength_++] = 19;
            break;
        case PreparedResourceKind.StrokeExtrudeActivationState:
            e.strokeExtrudeActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 20;
            break;
        case PreparedResourceKind.VertexMergeActivationState:
            e.vertexWeldActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 21;
            break;
        case PreparedResourceKind.PolyInsetActivationState:
            e.polyInsetActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 22;
            break;
        case PreparedResourceKind.PolyExtrudeActivationState:
            e.polyExtrudeActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 23;
            break;
        case PreparedResourceKind.SmoothShiftActivationState:
            e.smoothShiftActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 24;
            break;
        case PreparedResourceKind.EdgeBevelActivationState:
            e.edgeBevelActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 25;
            break;
        case PreparedResourceKind.PolyBevelActivationState:
            e.polyBevelActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 26;
            break;
        case PreparedResourceKind.VertexBevelActivationState:
            e.vertexBevelActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 27;
            break;
        case PreparedResourceKind.VertexExtrudeActivationState:
            e.vertexExtrudeActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 28;
            break;
        case PreparedResourceKind.EdgeExtrudeActivationState:
            e.edgeExtrudeActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 29;
            break;
        case PreparedResourceKind.EdgeSliceActivationState:
            e.edgeSliceActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 30;
            break;
        case PreparedResourceKind.LoopSliceActivationState:
            e.loopSliceActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 31;
            break;
        case PreparedResourceKind.SliceActivationState:
            e.sliceActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 32;
            break;
        case PreparedResourceKind.TackActivationState:
            e.tackActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 33;
            break;
        case PreparedResourceKind.CommandWrapperActivationState:
            e.commandWrapperActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 34;
            break;
        case PreparedResourceKind.BridgeActivationState:
            e.bridgeActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 35;
            break;
        case PreparedResourceKind.MirrorActivationState:
            e.mirrorActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 36;
            break;
        case PreparedResourceKind.EdgeExtendToolActivationPreState:
            e.edgeExtendToolActivation.installPre();
            version(unittest) installTrace_[installTraceLength_++] = 37;
            break;
        case PreparedResourceKind.EdgeExtendToolActivationPostState:
            e.edgeExtendToolActivation.installPost();
            version(unittest) installTrace_[installTraceLength_++] = 38;
            break;
        case PreparedResourceKind.TopologyPenActivationState:
            e.topologyPenActivation.install();
            version(unittest) installTrace_[installTraceLength_++] = 39;
            break;
        case PreparedResourceKind.TopologyPenUpdateState:
            e.topologyPenUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 42;
            break;
        case PreparedResourceKind.TopologyPenDeactivateState:
            e.topologyPenDeactivate.install();
            version(unittest) installTrace_[installTraceLength_++] = 58;
            break;
        case PreparedResourceKind.ArrayParamUpdateState:
            e.arrayParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 43;
            break;
        case PreparedResourceKind.MagnetParamUpdateState:
            e.magnetParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 44;
            break;
        case PreparedResourceKind.SmoothShiftParamUpdateState:
            e.smoothShiftParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 45;
            break;
        case PreparedResourceKind.EdgeBevelParamUpdateState:
            e.edgeBevelParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 46;
            break;
        case PreparedResourceKind.EdgeExtrudeParamUpdateState:
            e.edgeExtrudeParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 47;
            break;
        case PreparedResourceKind.PolyBevelParamUpdateState:
            e.polyBevelParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 48;
            break;
        case PreparedResourceKind.PolyExtrudeParamUpdateState:
            e.polyExtrudeParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 49;
            break;
        case PreparedResourceKind.PolyInsetParamUpdateState:
            e.polyInsetParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 50;
            break;
        case PreparedResourceKind.ReductionParamUpdateState:
            e.reductionParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 51;
            break;
        case PreparedResourceKind.VertexMergeParamUpdateState:
            e.vertexMergeParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 52;
            break;
        case PreparedResourceKind.VertexBevelParamUpdateState:
            e.vertexBevelParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 53;
            break;
        case PreparedResourceKind.VertexExtrudeParamUpdateState:
            e.vertexExtrudeParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 54;
            break;
        case PreparedResourceKind.SliceDeactivateState:
            e.sliceDeactivate.install();
            version(unittest) installTrace_[installTraceLength_++] = 55;
            break;
        case PreparedResourceKind.SliceParamUpdateState:
            e.sliceParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 64;
            break;
        case PreparedResourceKind.EdgeSliceDeactivateState:
            e.edgeSliceDeactivate.install();
            version(unittest) installTrace_[installTraceLength_++] = 65;
            break;
        case PreparedResourceKind.EdgeSliceParamUpdateState:
            e.edgeSliceParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 66;
            break;
        case PreparedResourceKind.LoopSliceDeactivateState:
            e.loopSliceDeactivate.install();
            version(unittest) installTrace_[installTraceLength_++] = 67;
            break;
        case PreparedResourceKind.LoopSliceParamUpdateState:
            e.loopSliceParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 68;
            break;
        case PreparedResourceKind.EdgeExtendParamUpdateState:
            e.edgeExtendParamUpdate.install();
            version(unittest) installTrace_[installTraceLength_++] = 69;
            break;
        case PreparedResourceKind.EdgeExtendDeactivateState:
            e.edgeExtendDeactivate.install();
            version(unittest) installTrace_[installTraceLength_++] = 70;
            break;
        case PreparedResourceKind.MirrorDeactivateState:
            e.mirrorDeactivate.install();
            version(unittest) installTrace_[installTraceLength_++] = 40;
            break;
        case PreparedResourceKind.BridgeDeactivateState:
            e.bridgeDeactivate.install();
            version(unittest) installTrace_[installTraceLength_++] = 41;
            break;
        }
        if (!installedHistory && history_ !is null)
            history_.installPreparedToken(validated_);
        resources_.length = 0;
        historyMarker_ = false;
        noHistoryMarker_ = false;
        xfrmLayoutOwner_ = null;
        xfrmLayoutStage_ = 0;
        validated_Once = false;
        begun_ = false;
    }

    void discard() nothrow @nogc {
        if (!begun_) return;
        // NoHistory validation never validates/consumes the history token;
        // allow a caller to abandon the fully validated resource journal.
        if (validated_Once && !noHistoryMarker_) return;
        if (history_ !is null) history_.discardPreparedToken(token_);
        abortResources();
        begun_ = false; validated_Once = false;
    }

private:
    void abortResources() nothrow @nogc {
        foreach (ref e; resources_) final switch (e.kind) {
        case PreparedResourceKind.HistoryInstall: break;
        case PreparedResourceKind.NoHistoryInstall: break;
        case PreparedResourceKind.MeshInstall: e.layerMesh.abortEnlistedMesh(); break;
        case PreparedResourceKind.DeliveryInstall: break;
        case PreparedResourceKind.GpuMeshDestroy: e.gpuDestroy.abortEnlisted(); break;
        case PreparedResourceKind.GpuUpload: e.gpuUpload.abortEnlisted(); break;
        case PreparedResourceKind.ClickPointDestroy: e.clickDestroy.abortEnlisted(); break;
        case PreparedResourceKind.BoxHandlerBatchDestroy:
            e.boxHandlersDestroy.abortEnlisted(); break;
        case PreparedResourceKind.GpuCreate: e.gpuCreate.abortEnlisted(); break;
        case PreparedResourceKind.SnapOverlayClear: e.snapOverlay.abortClear(); break;
        case PreparedResourceKind.BoxState:
        case PreparedResourceKind.PenState:
        case PreparedResourceKind.PrimitiveState:
        case PreparedResourceKind.VertexState: e.privateState.abort(); break;
        case PreparedResourceKind.ArraySessionState:
        case PreparedResourceKind.CloneSessionState:
        case PreparedResourceKind.MagnetSessionState:
        case PreparedResourceKind.ReductionSessionState: e.privateState.abort(); break;
        case PreparedResourceKind.RadialSweepProfileState: e.selectionProfile.abort(); break;
        case PreparedResourceKind.RadialSweepTransitionState: e.radialSweepTransition.abort(); break;
        case PreparedResourceKind.GestureCarrierMismatch: break;
        case PreparedResourceKind.GpuCreateUpload: e.gpuCreateUpload.abortEnlisted(); break;
        case PreparedResourceKind.CommandWrapperActivationState:
            e.commandWrapperActivation.abort(); break;
        case PreparedResourceKind.BridgeActivationState:
            e.bridgeActivation.abort(); break;
        case PreparedResourceKind.MirrorActivationState:
            e.mirrorActivation.abort(); break;
        case PreparedResourceKind.EdgeExtendToolActivationPreState:
        case PreparedResourceKind.EdgeExtendToolActivationPostState:
            e.edgeExtendToolActivation.abort(); break;
        case PreparedResourceKind.TopologyPenActivationState:
            e.topologyPenActivation.abort(); break;
        case PreparedResourceKind.TopologyPenUpdateState:
            e.topologyPenUpdate.abort(); break;
        case PreparedResourceKind.TopologyPenDeactivateState:
            e.topologyPenDeactivate.abort(); break;
        case PreparedResourceKind.ArrayParamUpdateState:
            e.arrayParamUpdate.abort(); break;
        case PreparedResourceKind.MagnetParamUpdateState:
            e.magnetParamUpdate.abort(); break;
        case PreparedResourceKind.SmoothShiftParamUpdateState:
            e.smoothShiftParamUpdate.abort(); break;
        case PreparedResourceKind.EdgeBevelParamUpdateState:
            e.edgeBevelParamUpdate.abort(); break;
        case PreparedResourceKind.EdgeExtrudeParamUpdateState:
            e.edgeExtrudeParamUpdate.abort(); break;
        case PreparedResourceKind.PolyBevelParamUpdateState:
            e.polyBevelParamUpdate.abort(); break;
        case PreparedResourceKind.PolyExtrudeParamUpdateState:
            e.polyExtrudeParamUpdate.abort(); break;
        case PreparedResourceKind.PolyInsetParamUpdateState:
            e.polyInsetParamUpdate.abort(); break;
        case PreparedResourceKind.ReductionParamUpdateState:
            e.reductionParamUpdate.abort(); break;
        case PreparedResourceKind.VertexMergeParamUpdateState:
            e.vertexMergeParamUpdate.abort(); break;
        case PreparedResourceKind.VertexBevelParamUpdateState:
            e.vertexBevelParamUpdate.abort(); break;
        case PreparedResourceKind.VertexExtrudeParamUpdateState:
            e.vertexExtrudeParamUpdate.abort(); break;
        case PreparedResourceKind.SliceDeactivateState:
            e.sliceDeactivate.abort(); break;
        case PreparedResourceKind.SliceParamUpdateState:
            e.sliceParamUpdate.abort(); break;
        case PreparedResourceKind.EdgeSliceDeactivateState:
            e.edgeSliceDeactivate.abort(); break;
        case PreparedResourceKind.EdgeSliceParamUpdateState:
            e.edgeSliceParamUpdate.abort(); break;
        case PreparedResourceKind.LoopSliceDeactivateState:
            e.loopSliceDeactivate.abort(); break;
        case PreparedResourceKind.LoopSliceParamUpdateState:
            e.loopSliceParamUpdate.abort(); break;
        case PreparedResourceKind.EdgeExtendParamUpdateState:
            e.edgeExtendParamUpdate.abort(); break;
        case PreparedResourceKind.EdgeExtendDeactivateState:
            e.edgeExtendDeactivate.abort(); break;
        case PreparedResourceKind.MirrorDeactivateState:
            e.mirrorDeactivate.abort(); break;
        case PreparedResourceKind.BridgeDeactivateState:
            e.bridgeDeactivate.abort(); break;
        case PreparedResourceKind.RadialArrayTransitionState:
            e.radialArrayTransition.abort(); break;
        case PreparedResourceKind.TransformActivationState:
            e.transformActivation.abort(); break;
        case PreparedResourceKind.TransformProductActivationState:
            e.transformProductActivation.abort(); break;
        case PreparedResourceKind.MoveUpdateState: e.moveUpdate.abort(); break;
        case PreparedResourceKind.RotateUpdateState: e.rotateUpdate.abort(); break;
        case PreparedResourceKind.ScaleUpdateState: e.scaleUpdate.abort(); break;
        case PreparedResourceKind.XfrmUpdateTailState: e.xfrmUpdateTail.abort(); break;
        case PreparedResourceKind.XfrmUpdateEditCloseState:
            e.xfrmUpdateEditClose.abort(); break;
        case PreparedResourceKind.XfrmSlotPollState: e.xfrmSlotPoll.abort(); break;
        case PreparedResourceKind.XfrmUpdateBoundaryState:
            e.xfrmUpdateBoundary.abort(); break;
        case PreparedResourceKind.XfrmMoveRegradeState:
            e.xfrmMoveRegrade.abort(); break;
        case PreparedResourceKind.InheritedNoopState: e.inheritedNoop.abort(); break;
        case PreparedResourceKind.XfrmActivationPreState:
        case PreparedResourceKind.XfrmActivationPostState:
            e.xfrmActivation.abort(); break;
        case PreparedResourceKind.StrokeExtrudeActivationState:
            e.strokeExtrudeActivation.abort(); break;
        case PreparedResourceKind.VertexMergeActivationState:
            e.vertexWeldActivation.abort(); break;
        case PreparedResourceKind.PolyInsetActivationState:
            e.polyInsetActivation.abort(); break;
        case PreparedResourceKind.PolyExtrudeActivationState:
            e.polyExtrudeActivation.abort(); break;
        case PreparedResourceKind.SmoothShiftActivationState:
            e.smoothShiftActivation.abort(); break;
        case PreparedResourceKind.EdgeBevelActivationState:
            e.edgeBevelActivation.abort(); break;
        case PreparedResourceKind.PolyBevelActivationState:
            e.polyBevelActivation.abort(); break;
        case PreparedResourceKind.VertexBevelActivationState:
            e.vertexBevelActivation.abort(); break;
        case PreparedResourceKind.VertexExtrudeActivationState:
            e.vertexExtrudeActivation.abort(); break;
        case PreparedResourceKind.EdgeExtrudeActivationState:
            e.edgeExtrudeActivation.abort(); break;
        case PreparedResourceKind.EdgeSliceActivationState:
            e.edgeSliceActivation.abort(); break;
        case PreparedResourceKind.LoopSliceActivationState:
            e.loopSliceActivation.abort(); break;
        case PreparedResourceKind.SliceActivationState:
            e.sliceActivation.abort(); break;
        case PreparedResourceKind.TackActivationState:
            e.tackActivation.abort(); break;
        }
        resources_.length = 0;
        historyMarker_ = false;
        noHistoryMarker_ = false;
        xfrmLayoutOwner_ = null;
        xfrmLayoutStage_ = 0;
    }

    void invalidateTransaction() nothrow @nogc {
        abortResources();
        if (begun_ && !validated_Once && history_ !is null)
            history_.discardPreparedToken(token_);
        begun_ = false;
        validated_Once = false;
    }
public:

    void installedDepths(out size_t modelDepth, out size_t uiDepth) const {
        modelDepth = 0; uiDepth = 0;
        if (history_ !is null) history_.undoDepthCounts(modelDepth, uiDepth);
    }
    version (unittest) const(ubyte)[] installTraceForTest() const nothrow @nogc {
        return installTrace_[0 .. installTraceLength_];
    }
    version (unittest) size_t resourceCountForTest() const nothrow @nogc {
        return resources_.length;
    }
    version (unittest) static void failAfterResourceBeginForTest(bool value)
            nothrow @nogc { failAfterResourceBegin_ = value; }
}

unittest {
    import command : Command, CmdFlags;
    import mesh : Mesh;
    import view : View;
    import editmode : EditMode;
    final class C : Command {
        private Mesh mesh_;
        private View view_ = new View(0, 0, 1, 1);
        this() { super(&mesh_, view_, EditMode.Vertices); }
        override string name() const { return "prepared.context.test"; }
        override string label() const { return "prepared context"; }
        override CmdFlags cmdFlags() const { return CmdFlags.Model; }
        protected override bool applyImpl() { return true; }
    }
    auto history = new CommandHistory();
    auto hub = new RecordObserverHub();
    hub.setMacroActive(true);
    auto context = new PreparedRecordContext(history, hub);
    auto result = context.prepare(new C(), PreparedHistoryKind.Plain);
    size_t models, ui;
    history.undoDepthCounts(models, ui);
    assert(result.accepted && models == 0 && hub.macroLength == 0);
    assert(context.validate());
    context.install();
    history.undoDepthCounts(models, ui);
    assert(models == 1 && hub.macroLength == 1);
    context.install();
    history.undoDepthCounts(models, ui);
    assert(models == 1 && hub.macroLength == 1);

    // A validated History journal owns a validated history/observer image:
    // discard is deliberately inert and the one later install remains exact.
    auto retainedHistory = new CommandHistory();
    auto retainedHub = new RecordObserverHub(); retainedHub.setMacroActive(true);
    auto retained = new PreparedRecordContext(retainedHistory, retainedHub);
    assert(retained.prepare(new C(), PreparedHistoryKind.Plain).accepted &&
        retained.validate());
    retained.discard();
    retainedHistory.undoDepthCounts(models, ui);
    assert(models == 0 && ui == 0 && retainedHub.macroLength == 0);
    retained.install(); retained.install();
    retainedHistory.undoDepthCounts(models, ui);
    assert(models == 1 && ui == 0 && retainedHub.macroLength == 1);

    // A context without a history is a supported NoHistory journal. Every
    // history-facing operation fails closed without poisoning that journal.
    auto empty = new PreparedRecordContext(null, new RecordObserverHub());
    assert(!empty.prepare(new C(), PreparedHistoryKind.Plain).accepted);
    assert(!empty.consolidate(1).accepted && empty.nextRun() == 0);
    assert(!empty.markHistoryInstall() && empty.resourceCountForTest() == 0);
    assert(empty.markNoHistoryInstall() && empty.validate());
    empty.install();
    assert(empty.installTraceForTest() == [8]);
}

version (unittest) unittest {
    import mesh : GpuMesh, makeCube;
    import handler : ClickPointHandler, ClickPointResourceOwner;
    import change_bus : changeBus;
    auto history = new CommandHistory();
    auto hub = new RecordObserverHub();

    // A validated NoHistory journal has no validated history image. Discard
    // must abort its resource, release the retained history token, and make
    // all subsequent operations inert; the same history immediately begins
    // and validates a fresh NoHistory transaction.
    auto boundaryHandle = new ClickPointHandler();
    auto boundaryOwner = new ClickPointResourceOwner(boundaryHandle, 7, 11);
    auto boundary = new PreparedRecordContext(history, hub);
    boundary.setResourceIdentity(7, 11);
    assert(boundary.prepareDestroy(boundaryOwner) &&
        boundary.markNoHistoryInstall() && boundary.validate());
    boundary.discard();
    assert(boundary.resourceCountForTest() == 0 && !boundary.validate());
    boundary.install(); assert(boundary.installTraceForTest().length == 0);
    auto boundaryFresh = new PreparedRecordContext(history, hub);
    assert(boundaryFresh.markNoHistoryInstall() && boundaryFresh.validate());
    boundaryFresh.discard(); assert(!boundaryFresh.validate());

    // Resource then history (Box/Primitive ordering).
    auto firstHandle = new ClickPointHandler();
    auto firstOwner = new ClickPointResourceOwner(firstHandle, 7, 11);
    auto first = new PreparedRecordContext(history, hub);
    first.setResourceIdentity(7, 11);
    assert(first.prepareDestroy(firstOwner));
    assert(first.markHistoryInstall());
    assert(first.validate());
    first.install();
    assert(first.installTrace_[0 .. first.installTraceLength_] == [2, 1]);

    // History then resource (CommandWrapper ordering).
    auto secondHandle = new ClickPointHandler();
    auto secondOwner = new ClickPointResourceOwner(secondHandle, 7, 11);
    auto second = new PreparedRecordContext(history, hub);
    second.setResourceIdentity(7, 11);
    assert(second.markHistoryInstall());
    assert(second.prepareDestroy(secondOwner));
    assert(second.validate());
    second.install();
    assert(second.installTrace_[0 .. second.installTraceLength_] == [1, 2]);

    // Allocation/post-begin failure cannot strand an owner; discard and a
    // fresh transaction can immediately enlist the same owner.
    GpuMesh faultGpu;
    auto faultOwner = new GpuResourceOwner(&faultGpu, 7, 11);
    auto fault = new PreparedRecordContext(history, hub);
    PreparedRecordContext.failAfterResourceBegin_ = true;
    bool threw;
    try fault.prepareDestroy(faultOwner);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBegin_ = false;
    assert(threw);
    fault.discard();
    auto retry = new PreparedRecordContext(history, hub);
    retry.setResourceIdentity(7, 11);
    assert(retry.prepareDestroy(faultOwner));
    assert(retry.markHistoryInstall());
    retry.discard();

    // A joint-validation refusal is terminal: even correcting the identity
    // cannot revive or partially install the discarded transaction.
    GpuMesh refusedGpu;
    auto refusedOwner = new GpuResourceOwner(&refusedGpu, 7, 11);
    auto refused = new PreparedRecordContext(history, hub);
    refused.setResourceIdentity(8, 11);
    assert(refused.prepareDestroy(refusedOwner));
    assert(refused.markHistoryInstall());
    assert(!refused.validate());
    refused.setResourceIdentity(7, 11);
    assert(!refused.validate());
    refused.install();
    auto afterRefusal = new PreparedRecordContext(history, hub);
    afterRefusal.setResourceIdentity(7, 11);
    assert(afterRefusal.prepareDestroy(refusedOwner));
    afterRefusal.discard();

    // A delivery allocation failure happens before either Mesh/Delivery row
    // is appended and terminally clears the earlier history marker. Live
    // state stays unchanged; the Layer is immediately reusable by a fresh
    // context.
    auto faultLayer = new Layer();
    faultLayer.meshRef() = makeCube();
    const faultVersion = faultLayer.meshRef().mutationVersion;
    const faultDeliveries = changeBus.deliveryCount;
    auto meshFault = new PreparedRecordContext(new CommandHistory(),
                                               new RecordObserverHub());
    assert(meshFault.markHistoryInstall());
    PreparedDeliveryJournal.setFailPrepareForTest(true);
    threw = false;
    try meshFault.preparePositionCommit(faultLayer);
    catch (Exception) threw = true;
    PreparedDeliveryJournal.setFailPrepareForTest(false);
    assert(threw && meshFault.resourceCountForTest() == 0);
    assert(faultLayer.meshRef().mutationVersion == faultVersion);
    assert(changeBus.deliveryCount == faultDeliveries);
    assert(!meshFault.validate());
    auto meshRetry = new PreparedRecordContext(new CommandHistory(),
                                               new RecordObserverHub());
    assert(meshRetry.markHistoryInstall());
    assert(meshRetry.preparePositionCommit(faultLayer));
    assert(meshRetry.validate());
    meshRetry.install();
    assert(faultLayer.meshRef().mutationVersion == faultVersion + 1);
    assert(changeBus.deliveryCount == faultDeliveries + 1);

    GpuMesh createdGpu;
    auto createOwner = GpuCreateOwner.fakeForTest(&createdGpu);
    auto snapOwner = new SnapOverlayOwner();
    auto failedCreate = new PreparedRecordContext(new CommandHistory(),
                                                  new RecordObserverHub());
    failedCreate.setResourceIdentity(7, 11);
    PreparedRecordContext.failAfterResourceBegin_ = true;
    threw = false;
    try failedCreate.prepareCreate(createOwner);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBegin_ = false;
    assert(threw && failedCreate.resourceCountForTest() == 0);
    assert(createdGpu.faceVao == 0 && createOwner.fakeCleanupCountForTest() == 1);
    auto mixed = new PreparedRecordContext(new CommandHistory(),
                                           new RecordObserverHub());
    mixed.setResourceIdentity(7, 11);
    assert(mixed.markHistoryInstall());
    assert(mixed.prepareCreate(createOwner));
    assert(mixed.prepareSnapClear(snapOwner));
    assert(createdGpu.faceVao == 0);
    assert(mixed.validate());
    mixed.install();
    assert(createdGpu.faceVao != 0);
    assert(mixed.installTraceForTest() == [1,5,6]);

    auto topologyLayer = new Layer();
    topologyLayer.meshRef() = makeCube();
    Mesh emptyImage;
    auto topology = new PreparedRecordContext(new CommandHistory(),
                                              new RecordObserverHub());
    assert(topology.markHistoryInstall());
    assert(topology.prepareMeshImageCommit(topologyLayer, emptyImage,
                                           MeshEditScope.Geometry));
    assert(topologyLayer.meshRef().vertices.length == 8);
    assert(topology.validate()); topology.install();
    assert(topologyLayer.meshRef().vertices.length == 0);
    assert(topology.installTraceForTest() == [1,3,4]);

    auto topologyFaultLayer = new Layer();
    topologyFaultLayer.meshRef() = makeCube();
    auto topologyFault = new PreparedRecordContext(new CommandHistory(),
                                                   new RecordObserverHub());
    assert(topologyFault.markHistoryInstall());
    PreparedDeliveryJournal.setFailPrepareForTest(true);
    threw = false;
    try topologyFault.prepareMeshImageCommit(topologyFaultLayer, emptyImage,
                                             MeshEditScope.Geometry);
    catch (Exception) threw = true;
    PreparedDeliveryJournal.setFailPrepareForTest(false);
    assert(threw && topologyFault.resourceCountForTest() == 0);
    assert(topologyFaultLayer.meshRef().vertices.length == 8);
    assert(!topologyFault.validate());
    auto topologyRetry = new PreparedRecordContext(new CommandHistory(),
                                                   new RecordObserverHub());
    assert(topologyRetry.markHistoryInstall());
    assert(topologyRetry.prepareMeshImageCommit(topologyFaultLayer, emptyImage,
                                                MeshEditScope.Geometry));
    topologyRetry.discard();
    assert(topologyFaultLayer.meshRef().vertices.length == 8);

    GpuMesh firstUploadGpu; Mesh firstUploadMesh = makeCube();
    GpuMesh failedFirstUploadGpu;
    auto failedCombinedOwner = GpuCreateUploadOwner.fakeForTest(&failedFirstUploadGpu);
    auto failedCombined = new PreparedRecordContext(new CommandHistory(),
                                                     new RecordObserverHub());
    failedCombined.setResourceIdentity(7, 11);
    PreparedRecordContext.failAfterResourceBegin_ = true;
    threw = false;
    try failedCombined.prepareCreateUpload(failedCombinedOwner, firstUploadMesh);
    catch (Exception) threw = true;
    PreparedRecordContext.failAfterResourceBegin_ = false;
    assert(threw && failedFirstUploadGpu.faceVao == 0 &&
        failedCombinedOwner.fakeCreatedForTest() ==
            failedCombinedOwner.fakeDeletedForTest());
    GpuMesh staleFirstUploadGpu;
    auto staleOwner = GpuCreateUploadOwner.fakeForTest(&staleFirstUploadGpu);
    auto staleContext = new PreparedRecordContext(new CommandHistory(),
                                                  new RecordObserverHub());
    staleContext.setResourceIdentity(7, 11);
    assert(staleContext.prepareCreateUpload(staleOwner, firstUploadMesh));
    staleFirstUploadGpu.uploadVersion = 1;
    assert(!staleContext.validate() &&
        staleOwner.fakeCreatedForTest() == staleOwner.fakeDeletedForTest());
    staleFirstUploadGpu.uploadVersion = 0;
    auto freshStaleOwner = GpuCreateUploadOwner.fakeForTest(&staleFirstUploadGpu);
    auto freshStaleContext = new PreparedRecordContext(new CommandHistory(),
                                                       new RecordObserverHub());
    freshStaleContext.setResourceIdentity(7, 11);
    assert(freshStaleContext.prepareCreateUpload(freshStaleOwner, firstUploadMesh));
    freshStaleContext.discard();
    auto combinedOwner = GpuCreateUploadOwner.fakeForTest(&firstUploadGpu);
    auto combined = new PreparedRecordContext(new CommandHistory(),
                                               new RecordObserverHub());
    combined.setResourceIdentity(7, 11);
    assert(combined.prepareCreateUpload(combinedOwner, firstUploadMesh));
    assert(combined.markNoHistoryInstall() && firstUploadGpu.faceVao == 0);
    assert(combined.validate()); combined.install();
    assert(firstUploadGpu.faceVao == 301 && firstUploadGpu.vertCount > 0);
    assert(combined.installTraceForTest() == [12,8]);

    GpuMesh abortedGpu;
    auto abortedOwner = GpuCreateUploadOwner.fakeForTest(&abortedGpu);
    auto abortedContext = new PreparedRecordContext(new CommandHistory(),
                                                    new RecordObserverHub());
    abortedContext.setResourceIdentity(7, 11);
    assert(abortedContext.prepareCreateUpload(abortedOwner, firstUploadMesh));
    abortedContext.discard();
    assert(abortedGpu.faceVao == 0 &&
        abortedOwner.fakeCreatedForTest() == abortedOwner.fakeDeletedForTest());
}

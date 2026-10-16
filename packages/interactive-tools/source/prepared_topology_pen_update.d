module prepared_topology_pen_update;

import core.atomic : atomicOp;
import vibe3d.editing.pipeline.contracts.operator : VectorStack;
import vibe3d.editing.contracts.prepared_tool_effect : PreparedTopologyPenUpdateKind;
import tools.edit.topology_pen.tool : TopologyPenTool,
    PreparedTopologyPenUpdateImage;

struct PreparedTopologyPenUpdateToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedTopologyPenUpdateToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextTopologyPenUpdateOwner;

final class PreparedTopologyPenUpdateOwner {
private:
    TopologyPenTool target_;
    PreparedTopologyPenUpdateImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedTopologyPenUpdateToken prepared_;
    ValidatedTopologyPenUpdateToken validatedToken_;
public:
    @disable this();
    static PreparedTopologyPenUpdateOwner prepare(TopologyPenTool target,
            ref VectorStack vts) {
        if (target is null || target.classinfo !is TopologyPenTool.classinfo)
            return null;
        auto owner = new PreparedTopologyPenUpdateOwner(target);
        owner.image_ = target.buildPreparedUpdate(vts);
        return owner.image_.valid ? owner : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is TopologyPenTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            !target_.preparedUpdateMatches(image_)) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedUpdate(image_); consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
    PreparedTopologyPenUpdateKind effectKind() const nothrow @nogc {
        if (!image_.valid) return PreparedTopologyPenUpdateKind.None;
        return image_.hasPacket ? PreparedTopologyPenUpdateKind.Packet :
            PreparedTopologyPenUpdateKind.PacketAbsent;
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && target_ is null;
    }
private:
    this(TopologyPenTool target) {
        target_ = target; owner_ = atomicOp!"+="(nextTopologyPenUpdateOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; pending_ = validated_ = false;
        consumed_ = true; prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

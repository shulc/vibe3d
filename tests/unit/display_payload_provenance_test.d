// Task 6520: an entry refusal publishes Position but must not claim that the
// display buffers were written. This is tested at the write site so a later
// preview producer cannot hide a false cage author.
module tests.unit.display_payload_provenance_test;

import change_bus : changeBus;
import mesh : Mesh, g_isDocumentMesh, makeCube;
import mesh_gpu : DisplayPayloadBasis, DisplayPayloadProvenance,
    DisplayPayloadWriter, GpuMesh;
import std.format : format;

unittest // control -> delivery floor -> target; order is load-bearing
{
    // Instrument control only: this proves the counter can move, not that
    // production wiring calls it.
    DisplayPayloadProvenance p;
    assert(p.writes == 0,
        "6520 refusal control: provenance did not start empty");
    assert(!DisplayPayloadProvenance.init.carriesLiveEdit(),
        "6520 fold: an unwritten payload claimed the live edit");
    p.recordWrite(DisplayPayloadWriter.fullUpload,
                  DisplayPayloadBasis.cageIndexed);
    assert(p.writes == 1 && p.basis == DisplayPayloadBasis.cageIndexed,
        "6520 refusal control: the write instrument cannot move");

    Mesh mesh = makeCube();
    GpuMesh gpu;
    gpu.suppressCageUpload = true;
    auto savedFilter = g_isDocumentMesh;
    scope(exit) g_isDocumentMesh = savedFilter;
    g_isDocumentMesh = (const(Mesh)* candidate) => candidate is &mesh;

    bool[] selected = new bool[](mesh.vertices.length);
    immutable ulong baseWrites = gpu.displayPayload.writes;
    immutable ulong selectedDeliveries = changeBus.deliveryCount;
    gpu.uploadSelectedVertices(mesh, selected);
    assert(changeBus.deliveryCount == selectedDeliveries + 1,
        "6520 refusal floor: the suppressed-cage arm did not run — a zero "
      ~ "write count below would mean nothing");
    assert(gpu.displayPayload.writes == baseWrites,
        format("6520 refusal: a refused selected-vertex upload recorded a "
             ~ "display write (writes moved to %d)",
               gpu.displayPayload.writes));

    immutable ulong baseWrites2 = gpu.displayPayload.writes;
    immutable ulong cageDeliveries = changeBus.deliveryCount;
    gpu.upload(mesh);
    assert(changeBus.deliveryCount == cageDeliveries + 1,
        "6520 refusal floor: the suppressed-cage arm did not run — a zero "
      ~ "write count below would mean nothing");
    assert(gpu.displayPayload.writes == baseWrites2,
        format("6520 refusal: a refused cage upload recorded a display "
             ~ "write (writes moved to %d)", gpu.displayPayload.writes));

    assert(gpu.displayPayload.writer == DisplayPayloadWriter.none
        && gpu.displayPayload.basis == DisplayPayloadBasis.none,
        "6520 refusal: a refused upload named an author");
}

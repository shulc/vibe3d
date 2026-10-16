module vibe3d.editing.tools.transform.tools.transform.cluster_values;

import vibe3d.util.math.math : Vec3;

// Shared cluster arrays retain the two-cluster activation law (task 20262060).
// Evidence: doc/application_layers_wave6_plan_2026-10-09.md.
struct ClusterPivots {
    Vec3[] centers;
    int [] clusterOf;
    bool active() const { return centers.length >= 2; }
}

struct ClusterAxes {
    Vec3[] right;
    Vec3[] up;
    Vec3[] fwd;
    bool active() const { return right.length >= 2; }
}

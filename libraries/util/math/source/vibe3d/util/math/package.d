module vibe3d.util.math;

public import vibe3d.util.math.math_vector :
    Vec3,
    Vec4,
    vec3Lerp,
    normalize,
    cross,
    dot,
    rotateAboutAxis,
    rotateAboutPivot,
    scaleAlongBasis,
    safeNormalize;

public import vibe3d.util.math.math_matrix :
    identityMatrix,
    translationMatrix,
    pivotRotationMatrix,
    pivotScaleMatrix,
    pivotScaleMatrixBasis,
    matrixFromEulerZYX,
    eulerZYXFromMatrix,
    applyAffine,
    transformPoint,
    matrixMirrorsWinding,
    normalMatrix,
    frameMatrix,
    frameMatrixInverse,
    matMul4,
    wrapAboutPivot,
    wrapAboutPivotStable,
    modelMatrix,
    mulMV,
    lookAt,
    perspectiveMatrix,
    orthographicMatrix;

public import vibe3d.util.math.math_quaternion :
    Quat,
    slerp,
    quatFromMatrix,
    matrixFromQuat;

public import vibe3d.util.math.math_geometry :
    faceNormalFirst3,
    pointInPolygon2D,
    frontFacingLocal,
    ringStartCornerSign,
    closestOnSegment2D,
    closestOnSegment2DSquared,
    rayPlaneIntersect,
    closestOnSegmentToRay,
    perpendicularFrame,
    rayTriangleIntersect,
    closestPointOnTriangle2D,
    triangulatePolygonEarClip,
    planeFromLineAndWorkplane,
    planeForSlice,
    snapAngleToMultiple,
    snapLineEndpointToAngle,
    closestPointOnSegmentToRay,
    closestPointOnLineToRay,
    offsetInPlane,
    offsetMeetDir,
    offsetMeet,
    bevelMiterPoint,
    bevelArcPoints;

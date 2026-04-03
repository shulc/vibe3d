module shader;

import bindbc.opengl;
import std.string : toStringz;


import view;
// ---------------------------------------------------------------------------
// Shaders
// ---------------------------------------------------------------------------

immutable string vertexShaderSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    uniform mat4 u_model;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    void main() {
        gl_Position = u_proj * u_view * u_model * vec4(aPos, 1.0);
    }
};

immutable string fragmentShaderSrc = q{
    #version 330 core
    uniform vec3 u_color;
    out vec4 fragColor;
    void main() {
        fragColor = vec4(u_color, 1.0);
    }
};

// Lit shaders — Blinn-Phong with flat per-face normals.
immutable string litVertSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    layout(location = 1) in vec3 aNormal;
    uniform mat4 u_model;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    out vec3 vNormal;
    out vec3 vWorldPos;
    void main() {
        vec4 worldPos = u_model * vec4(aPos, 1.0);
        vWorldPos     = worldPos.xyz;
        vNormal       = mat3(u_model) * aNormal;
        gl_Position   = u_proj * u_view * worldPos;
    }
};

immutable string litFragSrc = q{
    #version 330 core
    in  vec3 vNormal;
    in  vec3 vWorldPos;
    uniform vec3  u_color;
    uniform vec3  u_lightDir;  // normalized, world space
    uniform vec3  u_eyePos;
    uniform float u_ambient;
    uniform float u_specStr;
    uniform float u_specPow;
    out vec4 fragColor;
    void main() {
        vec3 N    = normalize(vNormal);
        vec3 L    = u_lightDir;
        vec3 V    = normalize(u_eyePos - vWorldPos);
        vec3 H    = normalize(L + V);
        float dif = max(dot(N, L), 0.0);
        float spc = pow(max(dot(N, H), 0.0), u_specPow);
        vec3  col = u_color * (u_ambient + dif * (1.0 - u_ambient))
                  + vec3(1.0) * spc * u_specStr;
        fragColor = vec4(col, 1.0);
    }
};

// Checkerboard overlay shader — every other screen pixel is discarded,
// the rest are filled with u_color.  Used to highlight selected faces.
immutable string checkerFragSrc = q{
    #version 330 core
    uniform vec3 u_color;
    out vec4 fragColor;
    void main() {
        if ((int(gl_FragCoord.x)/2 + int(gl_FragCoord.y)) % 2 == 0 || int(gl_FragCoord.x) % 2 == 0) discard;
        fragColor = vec4(u_color, 1.0);
    }
};

// Grid shaders — vertex passes world pos, fragment computes fade alpha.
immutable string gridVertSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    uniform mat4 u_model;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    out vec3 vWorldPos;
    void main() {
        vWorldPos   = (u_model * vec4(aPos, 1.0)).xyz;
        gl_Position = u_proj * u_view * vec4(vWorldPos, 1.0);
    }
};

immutable string gridFragSrc = q{
    #version 330 core
    uniform vec3  u_color;
    uniform float u_maxDist;     // world-space fade radius
    uniform vec2  u_screenSize;  // 3D viewport size in fb pixels
    uniform float u_vpOriginX;   // 3D viewport left edge in fb pixels
    uniform float u_vpOriginY;   // 3D viewport bottom edge in fb pixels
    in  vec3 vWorldPos;
    out vec4 fragColor;
    void main() {
        // Distance fade: full opacity at origin, zero at u_maxDist
        float dist      = length(vWorldPos.xz);
        float distAlpha = 1.0 - smoothstep(0.0, u_maxDist, dist);

        // Screen-edge fade (all four edges): min 20%
        float sx       = (gl_FragCoord.x - u_vpOriginX) / u_screenSize.x;
        float sy       = (gl_FragCoord.y - u_vpOriginY) / u_screenSize.y;
        float edgeFade = smoothstep(0.0, 0.15, sx) * smoothstep(1.0, 0.85, sx)
                       * smoothstep(0.0, 0.15, sy) * smoothstep(1.0, 0.85, sy);
        float edgeAlpha = mix(0.2, 1.0, edgeFade);

        fragColor = vec4(u_color, distAlpha * edgeAlpha);
    }
};

// ---------------------------------------------------------------------------
// Shader helpers
// ---------------------------------------------------------------------------

GLuint compileShader(GLenum type, string src) {
    GLuint shader = glCreateShader(type);
    const(char)* p = src.toStringz();
    glShaderSource(shader, 1, &p, null);
    glCompileShader(shader);
    GLint ok;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char[512] log;
        glGetShaderInfoLog(shader, 512, null, log.ptr);
        import std.conv : to;
        throw new Exception("Shader error: " ~ log[].to!string);
    }
    return shader;
}

GLuint createProgram(string vertSrc = vertexShaderSrc,
                     string fragSrc = fragmentShaderSrc) {
    GLuint vert = compileShader(GL_VERTEX_SHADER,   vertSrc);
    GLuint frag = compileShader(GL_FRAGMENT_SHADER, fragSrc);
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vert);
    glAttachShader(prog, frag);
    glLinkProgram(prog);
    GLint ok;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char[512] log;
        glGetProgramInfoLog(prog, 512, null, log.ptr);
        import std.conv : to;
        throw new Exception("Link error: " ~ log[].to!string);
    }
    glDeleteShader(vert);
    glDeleteShader(frag);
    return prog;
}

// Geometry shader that expands GL_LINES into screen-aligned quads
// to produce thick lines on macOS Core Profile (where glLineWidth > 1 is unsupported).
immutable string thickLineGeomSrc = q{
    #version 330 core
    layout(lines) in;
    layout(triangle_strip, max_vertices = 4) out;
    uniform float u_lineWidth;   // desired line width in pixels
    uniform vec2  u_screenSize;  // framebuffer size in pixels
    void main() {
        vec4 p0 = gl_in[0].gl_Position;
        vec4 p1 = gl_in[1].gl_Position;
        // Convert to screen space
        vec2 s0 = p0.xy / p0.w * u_screenSize;
        vec2 s1 = p1.xy / p1.w * u_screenSize;
        vec2 dir = s1 - s0;
        float len = length(dir);
        if (len < 0.001) return;
        // Perpendicular in screen space, half-width
        vec2 perp = vec2(-dir.y, dir.x) / len * (u_lineWidth * 0.5);
        // Back to NDC offsets (un-divide by w)
        vec2 off0 = perp / u_screenSize * p0.w;
        vec2 off1 = perp / u_screenSize * p1.w;
        gl_Position = vec4(p0.xy + off0, p0.zw); EmitVertex();
        gl_Position = vec4(p0.xy - off0, p0.zw); EmitVertex();
        gl_Position = vec4(p1.xy + off1, p1.zw); EmitVertex();
        gl_Position = vec4(p1.xy - off1, p1.zw); EmitVertex();
        EndPrimitive();
    }
};

GLuint createProgramWithGeom(string vertSrc, string geomSrc, string fragSrc) {
    GLuint vert = compileShader(GL_VERTEX_SHADER,   vertSrc);
    GLuint geom = compileShader(GL_GEOMETRY_SHADER, geomSrc);
    GLuint frag = compileShader(GL_FRAGMENT_SHADER, fragSrc);
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vert);
    glAttachShader(prog, geom);
    glAttachShader(prog, frag);
    glLinkProgram(prog);
    GLint ok;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char[512] log;
        glGetProgramInfoLog(prog, 512, null, log.ptr);
        import std.conv : to;
        throw new Exception("Link error: " ~ log[].to!string);
    }
    glDeleteShader(vert);
    glDeleteShader(geom);
    glDeleteShader(frag);
    return prog;
}

class Shader {
    GLuint program;
    GLint locModel;
    GLint locView;
    GLint locProj;
    GLint locColor;

    this() {
        program  = createProgram();
        locModel  = glGetUniformLocation(program, "u_model");
        locView   = glGetUniformLocation(program, "u_view");
        locProj   = glGetUniformLocation(program, "u_proj");
        locColor  = glGetUniformLocation(program, "u_color");
    }
    ~this() {  glDeleteProgram(program); }

    void useProgram(const ref float[16] meshModel, const ref View cameraView) {
        glUseProgram(program);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, meshModel.ptr);
        glUniformMatrix4fv(locView,  1, GL_FALSE, cameraView.view.ptr);
        glUniformMatrix4fv(locProj,  1, GL_FALSE, cameraView.proj.ptr);
    }
};

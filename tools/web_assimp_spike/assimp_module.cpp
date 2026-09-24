#include <assimp/cimport.h>
#include <assimp/scene.h>
#include <assimp/postprocess.h>
#include <cstdint>
#include <cstring>
#include <exception>
#include <stdexcept>
#include <string>
#include <vector>

// Probe wire v1: "V3DI", u32 version, u32 part count; per part:
// u32 name bytes, u32 vertices, u32 faces, u32 corners, UTF-8 name,
// xyz float32[vertices], u32 faceOffsets[faces+1], u32 indices[corners],
// uv float32[2*corners]. All integers and floats are little-endian.
// Import-only proof: no materials, morphs or visibility yet.
namespace {
std::vector<uint8_t> output;
std::string error;

void u32(std::vector<uint8_t>& dst, uint32_t value) {
    for (int n = 0; n < 4; ++n) dst.push_back(static_cast<uint8_t>(value >> (8*n)));
}
void f32(std::vector<uint8_t>& dst, float value) {
    uint32_t bits;
    std::memcpy(&bits, &value, 4);
    u32(dst, bits);
}
struct Part {
    std::string name;
    std::vector<aiVector3D> vertices;
    std::vector<uint32_t> offsets{0};
    std::vector<uint32_t> indices;
    std::vector<float> uv;
};
void walk(const aiScene* scene, const aiNode* node, const aiMatrix4x4& parent,
          std::vector<Part>& parts) {
    const aiMatrix4x4 world = parent * node->mTransformation;
    const float determinant = world.Determinant();
    for (unsigned m = 0; m < node->mNumMeshes; ++m) {
        const unsigned meshIndex = node->mMeshes[m];
        if (meshIndex >= scene->mNumMeshes) throw std::runtime_error("bad mesh index");
        const aiMesh* mesh = scene->mMeshes[meshIndex];
        if (!mesh || !mesh->mVertices) continue;
        Part part;
        part.name = node->mName.length ? node->mName.C_Str() : mesh->mName.C_Str();
        part.vertices.reserve(mesh->mNumVertices);
        for (unsigned v = 0; v < mesh->mNumVertices; ++v)
            part.vertices.push_back(world * mesh->mVertices[v]);
        for (unsigned f = 0; f < mesh->mNumFaces; ++f) {
            const aiFace& face = mesh->mFaces[f];
            if (face.mNumIndices < 3) continue;
            for (unsigned c = 0; c < face.mNumIndices; ++c) {
                const unsigned source = determinant < 0 ? face.mNumIndices - 1 - c : c;
                const unsigned index = face.mIndices[source];
                if (index >= mesh->mNumVertices) throw std::runtime_error("bad face index");
                part.indices.push_back(index);
                const aiVector3D tex = mesh->mTextureCoords[0]
                    ? mesh->mTextureCoords[0][index] : aiVector3D();
                part.uv.push_back(tex.x);
                part.uv.push_back(tex.y);
            }
            part.offsets.push_back(static_cast<uint32_t>(part.indices.size()));
        }
        if (part.offsets.size() > 1) parts.push_back(std::move(part));
    }
    for (unsigned c = 0; c < node->mNumChildren; ++c)
        walk(scene, node->mChildren[c], world, parts);
}
} // namespace

extern "C" {
int vibe_eh_probe() {
    try { throw std::runtime_error("caught inside Assimp module"); }
    catch (const std::runtime_error&) { return 7; }
}

int vibe_import_glb(const uint8_t* bytes, uint32_t length) {
    output.clear();
    error.clear();
    if (!bytes || !length) { error = "empty input"; return 0; }
    try {
        const aiScene* scene = aiImportFileFromMemory(reinterpret_cast<const char*>(bytes), length,
            aiProcess_JoinIdenticalVertices | aiProcess_GlobalScale |
            aiProcess_FindDegenerates | aiProcess_FindInvalidData, "glb");
        if (!scene) { error = aiGetErrorString(); return 0; }
        try {
            std::vector<Part> parts;
            aiMatrix4x4 identity;
            walk(scene, scene->mRootNode, identity, parts);
            if (parts.empty()) throw std::runtime_error("no polygon parts");
            output.insert(output.end(), {'V','3','D','I'});
            u32(output, 1);
            u32(output, static_cast<uint32_t>(parts.size()));
            for (const Part& p : parts) {
                u32(output, static_cast<uint32_t>(p.name.size()));
                u32(output, static_cast<uint32_t>(p.vertices.size()));
                u32(output, static_cast<uint32_t>(p.offsets.size() - 1));
                u32(output, static_cast<uint32_t>(p.indices.size()));
                output.insert(output.end(), p.name.begin(), p.name.end());
                for (const auto& v : p.vertices) { f32(output, v.x); f32(output, v.y); f32(output, v.z); }
                for (uint32_t value : p.offsets) u32(output, value);
                for (uint32_t value : p.indices) u32(output, value);
                for (float value : p.uv) f32(output, value);
            }
        } catch (...) { aiReleaseImport(scene); throw; }
        aiReleaseImport(scene);
        return 1;
    } catch (const std::exception& e) {
        output.clear();
        error = e.what();
        return 0;
    }
}
const uint8_t* vibe_result_ptr() { return output.data(); }
uint32_t vibe_result_len() { return static_cast<uint32_t>(output.size()); }
const char* vibe_error() { return error.c_str(); }
}

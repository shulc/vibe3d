#include <assimp/cexport.h>
#include <assimp/cimport.h>
#include <assimp/material.h>
#include <assimp/metadata.h>
#include <assimp/postprocess.h>
#include <assimp/scene.h>
#include <cstdint>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
std::vector<uint8_t> out;
std::string error;
void u32(uint32_t x) {
  for (int i = 0; i < 4; ++i)
    out.push_back(uint8_t(x >> (i * 8)));
}
void f32(float x) {
  uint32_t b;
  memcpy(&b, &x, 4);
  u32(b);
}
struct Reader {
  const uint8_t *p;
  size_t n, at = 0;
  void need(size_t k) {
    if (at > n || k > n - at)
      throw std::runtime_error("truncated scene wire");
  }
  uint32_t u32() {
    need(4);
    uint32_t x = uint32_t(p[at]) | (uint32_t(p[at + 1]) << 8) |
                 (uint32_t(p[at + 2]) << 16) | (uint32_t(p[at + 3]) << 24);
    at += 4;
    return x;
  }
  float f32() {
    uint32_t b = u32();
    float x;
    memcpy(&x, &b, 4);
    return x;
  }
  std::string str(size_t k) {
    need(k);
    std::string x((const char *)p + at, k);
    at += k;
    return x;
  }
  std::string str() { return str(u32()); }
};
void part(const aiScene *s, const aiNode *node, const aiMesh *mesh,
          const aiMatrix4x4 &parent, uint32_t &count) {
  if (!mesh || !mesh->mVertices || !mesh->mNumVertices)
    return;
  uint32_t faces = 0, corners = 0;
  for (unsigned i = 0; i < mesh->mNumFaces; ++i)
    if (mesh->mFaces[i].mNumIndices >= 3) {
      ++faces;
      corners += mesh->mFaces[i].mNumIndices;
    }
  if (!faces)
    return;
  ++count;
  const aiMatrix4x4 world = parent * node->mTransformation;
  const bool mirror = world.Determinant() < 0,
             uv = mesh->mTextureCoords[0] != nullptr;
  std::string name =
      node->mName.length ? node->mName.C_Str() : mesh->mName.C_Str();
  uint32_t surfaces = s->mNumMaterials ? s->mNumMaterials : 1;
  bool visible = true;
  if (node->mMetaData)
    node->mMetaData->Get("ml_visible", visible);
  u32(name.size());
  u32(mesh->mNumVertices);
  u32(faces);
  u32(corners);
  u32(surfaces);
  u32((visible ? 1 : 0) | (uv ? 2 : 0));
  for (int c = 0; c < 4; ++c)
    for (int r = 0; r < 4; ++r)
      f32(c == r ? 1.0f : 0.0f);
  out.insert(out.end(), name.begin(), name.end());
  for (unsigned i = 0; i < mesh->mNumVertices; ++i) {
    auto v = world * mesh->mVertices[i];
    f32(v.x);
    f32(v.y);
    f32(v.z);
  }
  u32(0);
  uint32_t offset = 0;
  for (unsigned i = 0; i < mesh->mNumFaces; ++i)
    if (mesh->mFaces[i].mNumIndices >= 3) {
      offset += mesh->mFaces[i].mNumIndices;
      u32(offset);
    }
  for (unsigned i = 0; i < mesh->mNumFaces; ++i) {
    const auto &f = mesh->mFaces[i];
    if (f.mNumIndices < 3)
      continue;
    for (unsigned k = 0; k < f.mNumIndices; ++k) {
      auto v = f.mIndices[mirror ? f.mNumIndices - 1 - k : k];
      if (v >= mesh->mNumVertices)
        throw std::runtime_error("bad face index");
      u32(v);
    }
  }
  if (uv)
    for (unsigned i = 0; i < mesh->mNumFaces; ++i) {
      const auto &f = mesh->mFaces[i];
      if (f.mNumIndices < 3)
        continue;
      for (unsigned k = 0; k < f.mNumIndices; ++k) {
        auto t =
            mesh->mTextureCoords[0][f.mIndices[mirror ? f.mNumIndices - 1 - k
                                                      : k]];
        f32(t.x);
        f32(t.y);
      }
    }
  for (unsigned i = 0; i < faces; ++i)
    u32(mesh->mMaterialIndex < surfaces ? mesh->mMaterialIndex : 0);
  for (unsigned i = 0; i < surfaces; ++i) {
    std::string name = "Default";
    aiColor4D color(.7f, .7f, .7f, 1);
    if (s->mNumMaterials) {
      aiString value;
      if (aiGetMaterialString(s->mMaterials[i], AI_MATKEY_NAME, &value) ==
          aiReturn_SUCCESS)
        name = value.C_Str();
      aiGetMaterialColor(s->mMaterials[i], AI_MATKEY_COLOR_DIFFUSE, &color);
    }
    u32(name.size());
    out.insert(out.end(), name.begin(), name.end());
    f32(color.r);
    f32(color.g);
    f32(color.b);
    f32(1);
    f32(0);
    f32(.4f);
    f32(color.a);
  }
}
void walk(const aiScene *s, const aiNode *n, const aiMatrix4x4 &parent,
          uint32_t &count) {
  auto world = parent * n->mTransformation;
  for (unsigned i = 0; i < n->mNumMeshes; ++i) {
    if (n->mMeshes[i] >= s->mNumMeshes)
      throw std::runtime_error("bad mesh index");
    part(s, n, s->mMeshes[n->mMeshes[i]], parent, count);
  }
  for (unsigned i = 0; i < n->mNumChildren; ++i)
    walk(s, n->mChildren[i], world, count);
}
aiScene *readScene(const uint8_t *bytes, size_t length, const char *format) {
  Reader r{bytes, length};
  if (r.str(4) != "V3DI" || r.u32() != 2)
    throw std::runtime_error("bad scene wire version");
  uint32_t count = r.u32();
  if (!count || count > 100000)
    throw std::runtime_error("bad part count");
  auto *scene = new aiScene();
  scene->mRootNode = new aiNode();
  scene->mRootNode->mName.Set("Root");
  scene->mNumMeshes = count;
  scene->mMeshes = new aiMesh *[count]();
  scene->mNumMaterials = 1;
  scene->mMaterials = new aiMaterial *[1]();
  scene->mMaterials[0] = new aiMaterial();
  scene->mRootNode->mNumChildren = count;
  scene->mRootNode->mChildren = new aiNode *[count]();
  try {
    for (uint32_t pi = 0; pi < count; ++pi) {
      uint32_t nameLen = r.u32(), verts = r.u32(), faces = r.u32(),
               corners = r.u32(), surfaces = r.u32(), flags = r.u32();
      if (!verts || !faces || verts > length / 12 || faces > length / 12 ||
          corners < uint64_t(faces) * 3 || corners > length / 4 || !surfaces ||
          surfaces > 100000)
        throw std::runtime_error("bad scene counts");
      float m[16];
      for (float &x : m)
        x = r.f32();
      auto name = r.str(nameLen);
      auto *node = new aiNode();
      scene->mRootNode->mChildren[pi] = node;
      node->mParent = scene->mRootNode;
      node->mName.Set(name);
      if (!(flags & 1)) {
        node->mMetaData = aiMetadata::Alloc(1);
        node->mMetaData->Set(0, "ml_visible", false);
      }
      node->mTransformation =
          aiMatrix4x4(m[0], m[4], m[8], m[12], m[1], m[5], m[9], m[13], m[2],
                      m[6], m[10], m[14], m[3], m[7], m[11], m[15]);
      node->mNumMeshes = 1;
      node->mMeshes = new unsigned[1]{pi};
      auto *mesh = new aiMesh();
      scene->mMeshes[pi] = mesh;
      mesh->mName.Set(name);
      std::vector<aiVector3D> positions(verts);
      for (auto &v : positions) {
        v.x = r.f32();
        v.y = r.f32();
        v.z = r.f32();
      }
      std::vector<uint32_t> offsets(faces + 1), indices(corners);
      for (auto &x : offsets)
        x = r.u32();
      if (offsets[0] || offsets.back() != corners)
        throw std::runtime_error("bad offsets");
      for (auto &x : indices) {
        x = r.u32();
        if (x >= verts)
          throw std::runtime_error("bad vertex index");
      }
      std::vector<float> uv;
      if (flags & 2) {
        uv.resize(size_t(corners) * 2);
        for (auto &x : uv)
          x = r.f32();
      }
      for (uint32_t i = 0; i < faces; ++i)
        (void)r.u32();
      for (uint32_t i = 0; i < surfaces; ++i) {
        (void)r.str();
        for (int j = 0; j < 7; ++j)
          (void)r.f32();
      }
      mesh->mNumVertices = corners;
      mesh->mVertices = new aiVector3D[corners];
      mesh->mNumFaces = faces;
      mesh->mFaces = new aiFace[faces];
      mesh->mPrimitiveTypes = aiPrimitiveType_POLYGON;
      if (flags & 2) {
        mesh->mTextureCoords[0] = new aiVector3D[corners];
        mesh->mNumUVComponents[0] = 2;
      }
      for (uint32_t i = 0; i < faces; ++i) {
        if (offsets[i + 1] < offsets[i] + 3 || offsets[i + 1] > corners)
          throw std::runtime_error("bad polygon");
        auto &f = mesh->mFaces[i];
        f.mNumIndices = offsets[i + 1] - offsets[i];
        f.mIndices = new unsigned[f.mNumIndices];
        for (uint32_t k = offsets[i]; k < offsets[i + 1]; ++k) {
          mesh->mVertices[k] = positions[indices[k]];
          if (flags & 2)
            mesh->mTextureCoords[0][k] =
                aiVector3D(uv[size_t(k) * 2], uv[size_t(k) * 2 + 1], 0);
          f.mIndices[k - offsets[i]] = k;
        }
      }
    }
    if (r.at != length)
      throw std::runtime_error("trailing wire bytes");
    if (strcmp(format, "fbx") == 0 || strcmp(format, "fbxa") == 0)
      for (unsigned i = 0; i < count; ++i)
        for (unsigned j = 0; j < scene->mMeshes[i]->mNumVertices; ++j)
          scene->mMeshes[i]->mVertices[j] *= 100.0f;
    return scene;
  } catch (...) {
    delete scene;
    throw;
  }
}
} // namespace
extern "C" {
int vibe_import_file(const char *path) {
  out.clear();
  error.clear();
  try {
    const aiScene *s = aiImportFile(
        path, aiProcess_JoinIdenticalVertices | aiProcess_GlobalScale |
                  aiProcess_FindDegenerates | aiProcess_FindInvalidData);
    if (!s) {
      error = aiGetErrorString();
      return 0;
    }
    try {
      out.insert(out.end(), {'V', '3', 'D', 'I'});
      u32(2);
      u32(0);
      uint32_t count = 0;
      aiMatrix4x4 identity;
      if (s->mRootNode)
        walk(s, s->mRootNode, identity, count);
      if (!count)
        throw std::runtime_error("no polygons");
      for (int i = 0; i < 4; ++i)
        out[8 + i] = uint8_t(count >> (i * 8));
    } catch (...) {
      aiReleaseImport(s);
      throw;
    }
    aiReleaseImport(s);
    return 1;
  } catch (const std::exception &e) {
    out.clear();
    error = e.what();
    return 0;
  }
}
int vibe_export_file(const uint8_t *bytes, uint32_t length, const char *format,
                     const char *path) {
  error.clear();
  try {
    std::unique_ptr<aiScene> s(readScene(bytes, length, format));
    auto rc = aiExportScene(s.get(), format, path, 0);
    if (rc != aiReturn_SUCCESS) {
      error = aiGetErrorString();
      return 0;
    }
    return 1;
  } catch (const std::exception &e) {
    error = e.what();
    return 0;
  }
}
const uint8_t *vibe_result_ptr() { return out.data(); }
uint32_t vibe_result_len() { return uint32_t(out.size()); }
const char *vibe_error() { return error.c_str(); }
}

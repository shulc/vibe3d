import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {join} from 'node:path';
const require=createRequire(import.meta.url);
const dir=process.argv[2];
const assimpSource=process.argv[3];
if(!dir||!assimpSource) throw new Error('usage: node tools/test_web_assimp_module.mjs <artifact-dir> <assimp-source>');
const a=await require(`${dir}/assimp_module.js`)();
const str=s=>{const n=a.lengthBytesUTF8(s)+1,p=a._malloc(n);a.stringToUTF8(s,p,n);return p;};
const imp=path=>{const p=str(path),ok=a._vibe_import_file(p);a._free(p);assert.equal(ok,1,a.UTF8ToString(a._vibe_error()));const n=a._vibe_result_len();return Uint8Array.from(a.HEAPU8.subarray(a._vibe_result_ptr(),a._vibe_result_ptr()+n));};
const exp=(wire,format,path)=>{const data=a._malloc(wire.length),f=str(format),p=str(path);a.HEAPU8.set(wire,data);const ok=a._vibe_export_file(data,wire.length,f,p);a._free(data);a._free(f);a._free(p);return ok;};
a.FS.mkdirTree('/io');
a.FS.writeFile('/io/quad.obj','o Quad\nv 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 1 1\nvt 0 1\nf 1/1 2/2 3/3 4/4\n');
const wire=imp('/io/quad.obj');
assert.equal(String.fromCharCode(...wire.subarray(0,4)),'V3DI');
assert.equal(new DataView(wire.buffer).getUint32(4,true),2);
const bounds=bytes=>{
 const v=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
 const count=v.getUint32(16,true),nameLength=v.getUint32(12,true);
 const begin=12+24+64+nameLength;
 let maxX=-Infinity,maxY=-Infinity;
 for(let i=0;i<count;i++) { maxX=Math.max(maxX,v.getFloat32(begin+i*12,true)); maxY=Math.max(maxY,v.getFloat32(begin+i*12+4,true)); }
 return [maxX,maxY];
};
for(const [id,ext] of [['obj','obj'],['glb2','glb'],['gltf2','gltf'],['fbx','fbx']]) {
  assert.equal(exp(wire,id,`/io/out.${ext}`),1,`${id}: ${a.UTF8ToString(a._vibe_error())}`);
  assert.ok(a.FS.stat(`/io/out.${ext}`).size>0);
  const back=imp(`/io/out.${ext}`);
  assert.ok(back.length>40);
  assert.ok(bounds(back).every(x=>Math.abs(x-1)<1e-3),`${id} changed quad scale: ${bounds(back)}`);
  console.log(`${id} export/import: ${a.FS.stat(`/io/out.${ext}`).size} bytes, wire ${back.length}`);
}
const hidden=wire.slice();
hidden[32] &= ~1;
assert.equal(exp(hidden,'glb2','/io/hidden.glb'),1,a.UTF8ToString(a._vibe_error()));
assert.equal(imp('/io/hidden.glb')[32]&1,0,'glTF node visibility metadata round-trips');
console.log('glTF visibility metadata: PASS');
const glb=join(assimpSource,'test/models/glTF2/BoxTextured-glTF-Binary/BoxTextured.glb');
a.FS.writeFile('/io/box.glb',readFileSync(glb));
assert.ok(imp('/io/box.glb').length>40);
const fbx=join(assimpSource,'test/models/FBX/box.fbx');
a.FS.writeFile('/io/x.fbx',readFileSync(fbx));
assert.ok(imp('/io/x.fbx').length>40);
const corrupt=wire.slice();corrupt[0]=0;
assert.equal(exp(corrupt,'obj','/io/bad.obj'),0);
assert.ok(a.UTF8ToString(a._vibe_error()).length);
const v=new DataView(wire.buffer,wire.byteOffset,wire.byteLength);
const nameLen=v.getUint32(12,true), verts=v.getUint32(16,true);
const faces=v.getUint32(20,true), corners=v.getUint32(24,true);
const flags=v.getUint32(32,true);
const materialAt=12+24+64+nameLen+verts*12+(faces+1)*4+corners*4+
  ((flags&2)?corners*8:0)+faces*4;
assert.equal(materialAt+4+v.getUint32(materialAt,true)+28,wire.length);
const noMaterial=wire.slice(0,materialAt);noMaterial.fill(0,28,32);
assert.equal(exp(noMaterial,'obj','/io/bad-material.obj'),0);
console.log('GLB and FBX imports, bad wire rejection: PASS');

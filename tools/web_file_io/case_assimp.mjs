#!/usr/bin/env node
// Real browser command path for the isolated Assimp wasm.
import assert from 'node:assert/strict';
import {mkdirSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {launch} from './driver.mjs';
const [chromium,base,scratch,assimpSource]=process.argv.slice(2);
mkdirSync(scratch,{recursive:true});
const root=join(assimpSource,'test/models/glTF2');
const fixtures={
 obj: [join(scratch,'quad.obj')],
 glb: [join(root,'BoxTextured-glTF-Binary/BoxTextured.glb')],
 gltf: [join(root,'BoxTextured-glTF/BoxTextured.gltf'),join(root,'BoxTextured-glTF/BoxTextured0.bin'),join(root,'BoxTextured-glTF/CesiumLogoFlat.png')],
 fbx: [join(assimpSource,'test/models/FBX/box.fbx')]
};
writeFileSync(fixtures.obj[0],'o Quad\nv 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n');
const broken=join(scratch,'broken.glb');
writeFileSync(broken,Buffer.from('glTF0000'));
async function page(id,body) {
 const label=id.replaceAll('.','-');
 const downloadDir=join(scratch,'downloads-'+label);
 mkdirSync(downloadDir,{recursive:true});
 const b=await launch({chromium,url:`${base}/?probe=assimp-${label}&dispatch=${id}`,
 profile:join(scratch,'profile-'+label),downloadDir});
 try { await b.waitFor(/WEB-FIRST-FRAME-COMPLETE/,90000); return await body(b); }
 catch(e) { console.log(b.lines.slice(-45).join('\n')); throw e; }
 finally { await b.stop(); }
}
for(const [ext,files] of Object.entries(fixtures)) await page('file.import.'+ext,async b=>{
 const mark=b.lines.length,n=b.choosers.length;
 await b.chord('F9','F9',120,0);
 await b.waitFor(new RegExp(`^WEB-PROBE-DISPATCH id=file\\.import\\.${ext}$`),20000,mark);
 const chooser=await b.waitChooser(n+1,20000);
 assert.equal(chooser.mode,ext==='obj'||ext==='gltf'?'selectMultiple':'selectSingle');
 await b.choose(chooser,files);
 await b.waitFor(/^WEB-PICK done token=\d+ files=\d+$/,20000,mark);
 const state=(await b.waitFor(/^WEB-DOC-STATE layers=1 verts=\d+ faces=\d+ images=0 docPath= dirty=1 /,30000,mark)).line;
 assert.equal(b.since(mark,/^WEB-NOTICE /).length,0);
 console.log(`WEB-ASSIMP import ${ext} ok ${state}`);
});
await page('file.import.glb',async b=>{
 const mark=b.lines.length,n=b.choosers.length;
 await b.chord('F9','F9',120,0);
 const chooser=await b.waitChooser(n+1,20000);
 await b.choose(chooser,[broken]);
 await b.waitFor(/^WEB-PICK done token=\d+ files=1$/,20000,mark);
 await b.waitFor(/^WEB-PICK-QUEUE parked=0$/,20000,mark);
 await b.waitFor(/^WEB-NOTICE .*assimp could not read this scene/,20000,mark);
 await b.sleep(200);
 const state=[...b.lines].reverse().find(x=>x.startsWith('WEB-DOC-STATE '));
 assert.match(state,/^WEB-DOC-STATE layers=1 verts=8 faces=6 images=0 docPath= dirty=0 /);
 console.log('WEB-ASSIMP reject broken GLB ok');
});
for(const ext of ['obj','gltf','glb','fbx']) await page('file.export.'+ext,async b=>{
 const mark=b.lines.length,known=new Set(b.downloads.keys());
 await b.chord('F9','F9',120,0);
 await b.waitFor(new RegExp(`^WEB-PROBE-DISPATCH id=file\\.export\\.${ext}$`),20000,mark);
 const d=await b.waitDownload(known,30000);
 assert.ok(d.bytes.length>100);
 if(ext==='gltf'||ext==='obj') {
  assert.ok(d.name.endsWith('.zip'),d.name);
  assert.equal(d.bytes.readUInt32LE(0),0x04034b50);
 } else assert.equal(d.name,'Untitled.'+ext);
 assert.equal(b.since(mark,/^WEB-NOTICE /).length,0);
 console.log(`WEB-ASSIMP export ${ext} ok ${d.name} ${d.bytes.length} bytes`);
});
// Export a real two-layer document and import the resulting GLB through a
// second command. The one-part cube checks above cannot witness lost layers.
const twoLayers=fileURLToPath(new URL('../../tests/fixtures/web_io/two_layers.v3d',import.meta.url));
const multiGlb=await page('file.export.glb',async b=>{
 const count=b.choosers.length;
 await b.chord('o','KeyO',79,2);
 const chooser=await b.waitChooser(count+1,20000);
 await b.choose(chooser,[twoLayers]);
 await b.waitFor(/^WEB-DOC-STATE layers=2 verts=562 faces=582 /,30000);
 const known=new Set(b.downloads.keys());
 await b.chord('F9','F9',120,0);
 const d=await b.waitDownload(known,30000);
 const path=join(scratch,'two_layers.glb');
 writeFileSync(path,d.bytes);
 console.log(`WEB-ASSIMP layered export glb ok ${d.bytes.length} bytes`);
 return path;
});
await page('file.import.glb',async b=>{
 const mark=b.lines.length,count=b.choosers.length;
 await b.chord('F9','F9',120,0);
 const chooser=await b.waitChooser(count+1,20000);
 await b.choose(chooser,[multiGlb]);
 const state=(await b.waitFor(/^WEB-DOC-STATE layers=2 verts=\d+ faces=\d+ images=0 docPath= dirty=1 /,30000,mark)).line;
 console.log(`WEB-ASSIMP layered import glb ok ${state}`);
});

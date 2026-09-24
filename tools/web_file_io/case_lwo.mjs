#!/usr/bin/env node
// Browser cells for LWO through the web file bridge (task 7440, plan
// doc/web_file_io_plan_2026-09-23.md S3): open an .lwo with the real chooser
// (File > Open and Import > LWO), export it as a download (Export > LWO),
// undo / redo of the import, and a broken .lwo. No source path is LWO-specific
// on the web: FileLoad dispatches `.lwo` to the LWO reader and FileSave's
// `.lwo` export to the LWO writer, exactly as on the desktop. Every cell waits
// on a PRODUCTION console line; the expected numbers come from the desktop
// oracle tests/unit/web_io_lwo_fixture_test.d, which pins these literals.
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { launch, sha256File } from './driver.mjs';

const [chromium, baseUrl, scratch, fixtures, mode] = process.argv.slice(2);
if (![chromium, baseUrl, scratch, fixtures, mode].every(Boolean))
  throw new Error('usage: case_lwo.mjs CHROMIUM BASE_URL SCRATCH FIXTURES MODE');

// Desktop oracle of tests/fixtures/web_io/two_parts.lwo (two LAYR chunks).
const V = 562, F = 582;
const parts = join(fixtures, 'two_parts.lwo');
const truncated = join(fixtures, 'truncated.lwo');
const exportSha = sha256File(join(fixtures, 'two_parts.export.lwo'));

const DEADLINE = 20000;
const ok = (cell, detail) => console.log(`WEB-FILE-IO-CELL ${cell} ok ${detail}`);
const fail = (cell, why) => { throw new Error(`WEB-FILE-IO-CELL ${cell} FAILED: ${why}`); };

// One page per probe-dispatch id: F9 dispatches the id the URL names.
async function page(dispatch, body) {
  const downloadDir = join(scratch, `downloads-lwo-${dispatch}-${mode}`);
  mkdirSync(downloadDir, { recursive: true });
  const url = `${baseUrl}/?probe=w17-file-io-lwo-${mode}&dispatch=${dispatch}`;
  const b = await launch({ chromium, url,
    profile: join(scratch, `profile-lwo-${dispatch}-${mode}`), downloadDir });
  try {
    await b.waitFor(/WEB-FIRST-FRAME-COMPLETE/, 90000);
    await body(b);
  } catch (e) {
    console.log(b.lines.slice(-40).join("\n"));
    console.log("CHOOSERS " + JSON.stringify(b.choosers));
    throw e;
  } finally {
    await b.stop();
  }
}

const lastOf = (b, prefix) => [...b.lines].reverse().find(l => l.startsWith(prefix));
const core = line => line.replace(/ title=.*$/, '');
const undoOf = line => Number(/ undo=(\d+) /.exec(line)[1]);
const importedState = undo => new RegExp(
  `^WEB-DOC-STATE layers=2 verts=${V} faces=${F} images=0 docPath= dirty=1 undo=${undo} `);

await page('file.export.lwo', async b => {
  const ctrlO = () => b.chord('o', 'KeyO', 79, 2);
  const ctrlZ = () => b.chord('z', 'KeyZ', 90, 2);
  const ctrlShiftZ = () => b.chord('Z', 'KeyZ', 90, 2 | 8);
  const f9 = () => b.chord('F9', 'F9', 120, 0);
  const openChooser = async () => {
    const n = b.choosers.length;
    await ctrlO();
    return b.waitChooser(n + 1, DEADLINE);
  };

  // L0 start: the default cube, clean — the floor L1 must move and L2 restore.
  const l0 = (await b.waitFor(/^WEB-DOC-STATE layers=1 verts=8 faces=6 images=0 docPath= dirty=0 /, DEADLINE)).line;
  const u0 = undoOf(l0);
  ok('L0', l0);

  // L4 broken .lwo (the first 60 bytes of two_parts.lwo), on the CLEAN cube so
  // no unsaved-changes guard stands between the choice and the load: the
  // reader rejects it, and the refusal is SILENT as on the desktop (the oracle pins an empty
  // refusal reason) — no notice, no state change, the pick drained and its
  // MEMFS directory removed.
  let mark = b.lines.length;
  const before4 = lastOf(b, 'WEB-DOC-STATE ');
  const dirs4 = lastOf(b, 'WEB-WORK-DIRS ');
  const ch4 = await openChooser();
  await b.waitFor(/^WEB-PICK-QUEUE parked=1$/, DEADLINE, mark);
  await b.choose(ch4, [truncated]);
  await b.waitFor(/^WEB-PICK done token=\d+ files=1$/, DEADLINE, mark);
  const reject = (await b.waitFor(/^\[io\] LWO: reject: no usable geometry$/, DEADLINE, mark)).line;
  await b.waitFor(/^WEB-PICK-QUEUE parked=0$/, DEADLINE, mark);
  await b.sleep(1000);
  if (b.since(mark, /^WEB-NOTICE /).length) fail('L4', `notice: ${b.since(mark, /^WEB-NOTICE /)}`);
  // The title alone may still move (a startup `[building subpatch preview...]`
  // suffix clears on its own); every other field must stand.
  const changed4 = b.since(mark, /^WEB-DOC-STATE /).filter(l => core(l) !== core(before4));
  if (changed4.length) fail('L4', `state changed: ${changed4}`);
  if (lastOf(b, 'WEB-WORK-DIRS ') !== dirs4)
    fail('L4', `the refused pick left its directory: ${dirs4} -> ${lastOf(b, 'WEB-WORK-DIRS ')}`);
  ok('L4', `${reject} | ${dirs4}`);

  // L1 File > Open of an .lwo: the LWO reader runs on the MEMFS path, the
  // two parts become two layers, the document stays untitled (interchange
  // import: FileLoad's document-path memory is .v3d-only) and dirty.
  mark = b.lines.length;
  const ch1 = await openChooser();
  if (ch1.mode !== 'selectMultiple') fail('L1', `chooser mode ${ch1.mode}`);
  await b.choose(ch1, [parts]);
  const read1 = (await b.waitFor(/^\[io\] LWO: sceneFromLwo: path=\/work\/\d+\/two_parts\.lwo$/, DEADLINE, mark)).line;
  const l1 = (await b.waitFor(importedState(u0 + 1), DEADLINE, mark)).line;
  ok('L1', `${read1} | ${l1}`);

  // L3 Export > LWO (the probe door dispatches `file.export.lwo`, the id the
  // menu row carries): the untitled document downloads as Untitled.lwo, bytes
  // equal to the desktop export of the same import. An export leaves the
  // document untitled and dirty.
  mark = b.lines.length;
  const known = new Set(b.downloads.keys());
  await f9();
  await b.waitFor(/^WEB-PROBE-DISPATCH id=file\.export\.lwo$/, DEADLINE, mark);
  const d3 = await b.waitDownload(known, DEADLINE);
  if (d3.name !== 'Untitled.lwo') fail('L3', `download named ${d3.name}`);
  if (d3.sha256 !== exportSha)
    fail('L3', `sha256 ${d3.sha256} != two_parts.export.lwo ${exportSha} (${d3.bytes.length} bytes)`);
  await b.sleep(1000);
  if (b.since(mark, /^WEB-NOTICE /).length) fail('L3', `notice: ${b.since(mark, /^WEB-NOTICE /)}`);
  if (!importedState(u0 + 1).test(lastOf(b, 'WEB-DOC-STATE ')))
    fail('L3', `the export changed the document state: ${lastOf(b, 'WEB-DOC-STATE ')}`);
  ok('L3', `name=${d3.name} bytes=${d3.bytes.length} sha256=${d3.sha256}`);

  // L2 undo of the import: back to the cube, the undo depth of L0.
  mark = b.lines.length;
  await ctrlZ();
  const l2 = (await b.waitFor(new RegExp(`^WEB-DOC-STATE layers=1 verts=8 faces=6 images=0 docPath= .* undo=${u0} `), DEADLINE, mark)).line;
  ok('L2', l2);

  // L2r redo: the two layers again, the undo depth of L1.
  mark = b.lines.length;
  await ctrlShiftZ();
  const l2r = (await b.waitFor(importedState(u0 + 1), DEADLINE, mark)).line;
  ok('L2r', l2r);
});

await page('file.import.lwo', async b => {
  const f9 = () => b.chord('F9', 'F9', 120, 0);
  const l0 = (await b.waitFor(/^WEB-DOC-STATE layers=1 verts=8 faces=6 images=0 docPath= dirty=0 /, DEADLINE)).line;
  // L5 Import > LWO (the probe door dispatches `file.import.lwo`): the same
  // import as L1 through the single-format command.
  const mark = b.lines.length;
  const n = b.choosers.length;
  await f9();
  await b.waitFor(/^WEB-PROBE-DISPATCH id=file\.import\.lwo$/, DEADLINE, mark);
  const ch5 = await b.waitChooser(n + 1, DEADLINE);
  if (ch5.mode !== 'selectMultiple') fail('L5', `chooser mode ${ch5.mode}`);
  await b.choose(ch5, [parts]);
  const l5 = (await b.waitFor(importedState(undoOf(l0) + 1), DEADLINE, mark)).line;
  ok('L5', l5);
});

console.log(`WEB-FILE-IO-LWO mode=${mode} cells=L0..L5,L2r ok`);

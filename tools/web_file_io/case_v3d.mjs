#!/usr/bin/env node
// Browser cells for `.v3d` open / undo / redo / save-download / broken file /
// cancel / unsaved-changes guard (task 7420, plan doc/web_file_io_plan_2026-09-23.md
// S2). Every cell waits on a PRODUCTION console line; the expected numbers come
// from the desktop oracle of the fixture (tests/unit/web_io_fixture_test.d pins
// the same literals), never from this run.
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { launch, sha256File } from './driver.mjs';

const [chromium, baseUrl, scratch, fixtures, mode] = process.argv.slice(2);
if (![chromium, baseUrl, scratch, fixtures, mode].every(Boolean))
  throw new Error('usage: case_v3d.mjs CHROMIUM BASE_URL SCRATCH FIXTURES MODE');

// Desktop oracle of tests/fixtures/web_io/two_layers.v3d (a cube and a sphere).
const V = 562, F = 582;
const two = join(fixtures, 'two_layers.v3d');
const truncated = join(fixtures, 'truncated.v3d');
const resaveSha = sha256File(join(fixtures, 'two_layers.resave.v3d'));

const downloadDir = join(scratch, `downloads-${mode}`);
mkdirSync(downloadDir, { recursive: true });
const url = `${baseUrl}/?probe=w17-file-io-${mode}&dispatch=mesh.subdivide`;
const b = await launch({ chromium, url, profile: join(scratch, `profile-io-${mode}`), downloadDir });

const DEADLINE = 20000;
// The cells that actually passed, in order (task 7450): the summary is built
// from them, and tools/test_web_file_io.sh requires each expected cell line
// exactly once, so a disabled cell cannot hide behind a fixed summary.
const ran = [];
const ok = (cell, detail) => { ran.push(cell); console.log(`WEB-FILE-IO-CELL ${cell} ok ${detail}`); };
const fail = (cell, why) => { throw new Error(`WEB-FILE-IO-CELL ${cell} FAILED: ${why}`); };
const ctrlO = () => b.chord('o', 'KeyO', 79, 2);
const ctrlS = () => b.chord('s', 'KeyS', 83, 2);
const ctrlZ = () => b.chord('z', 'KeyZ', 90, 2);
const ctrlShiftZ = () => b.chord('Z', 'KeyZ', 90, 2 | 8);
const f9 = () => b.chord('F9', 'F9', 120, 0);
// Ctrl+O and the chooser it opened (counted from now: a cancelled chooser
// also reports `fileChooserOpened`).
const openChooser = async () => {
  const n = b.choosers.length;
  await ctrlO();
  return b.waitChooser(n + 1, DEADLINE);
};
const lastState = () => [...b.lines].reverse().find(l => l.startsWith('WEB-DOC-STATE '));
const undoOf = line => Number(/ undo=(\d+) /.exec(line)[1]);

try {
  await b.waitFor(/WEB-FIRST-FRAME-COMPLETE/, 90000);

  // C0 start: the default cube, clean. Floor and negative control for C1.
  const c0 = (await b.waitFor(/^WEB-DOC-STATE layers=1 verts=8 faces=6 images=0 docPath= dirty=0 /, DEADLINE)).line;
  const u0 = undoOf(c0);
  ok('C0', c0);

  // C1 open: Ctrl+O -> the browser chooser (multiple) -> the fixture.
  let mark = b.lines.length;
  const ch1 = await openChooser();
  if (ch1.mode !== 'selectMultiple') fail('C1', `chooser mode ${ch1.mode}`);
  // The command is parked while the chooser is open (floor for C7's parked=0).
  await b.waitFor(/^WEB-PICK-QUEUE parked=1$/, DEADLINE, mark);
  await b.choose(ch1, [two]);
  const c1re = new RegExp(`^WEB-DOC-STATE layers=2 verts=${V} faces=${F} images=0 docPath=/work/\\d+/two_layers\\.v3d dirty=0 undo=${u0 + 1} title=two_layers\\.v3d - Vibe3d`);
  const c1 = (await b.waitFor(c1re, DEADLINE, mark)).line;
  await b.waitFor(/^WEB-PICK-QUEUE parked=0$/, DEADLINE, mark);
  ok('C1', c1);

  // C2 undo: back to the cube.
  mark = b.lines.length;
  await ctrlZ();
  const c2 = (await b.waitFor(new RegExp(`^WEB-DOC-STATE layers=1 verts=8 faces=6 images=0 .* undo=${u0} `), DEADLINE, mark)).line;
  ok('C2', c2);

  // C3 redo (config/shortcuts.yaml history.redo: Ctrl+Shift+Z): C1 again.
  mark = b.lines.length;
  await ctrlShiftZ();
  const c3 = (await b.waitFor(new RegExp(`^WEB-DOC-STATE layers=2 verts=${V} faces=${F} images=0 docPath=/work/\\d+/two_layers\\.v3d .* undo=${u0 + 1} `), DEADLINE, mark)).line;
  ok('C3', c3);

  // C4 save: Ctrl+S downloads bytes equal to the desktop writer's resave.
  let known = new Set(b.downloads.keys());
  await ctrlS();
  const d4 = await b.waitDownload(known, DEADLINE);
  if (d4.name !== 'two_layers.v3d') fail('C4', `download named ${d4.name}`);
  if (d4.sha256 !== resaveSha) fail('C4', `sha256 ${d4.sha256} != resave ${resaveSha} (${d4.bytes.length} bytes)`);
  ok('C4', `name=${d4.name} bytes=${d4.bytes.length} sha256=${d4.sha256}`);

  // C4b save clears dirty (owner Q6): dirty=1 first (floor), then Ctrl+S.
  mark = b.lines.length;
  await f9();
  await b.waitFor(/^WEB-PROBE-DISPATCH id=mesh\.subdivide/, DEADLINE, mark);
  const dirty = await b.waitFor(/^WEB-DOC-STATE .* dirty=1 /, DEADLINE, mark);
  known = new Set(b.downloads.keys());
  await ctrlS();
  const d4b = await b.waitDownload(known, DEADLINE);
  const clean = (await b.waitFor(/^WEB-DOC-STATE .* dirty=0 /, DEADLINE, dirty.index + 1)).line;
  ok('C4b', `download=${d4b.name} then ${clean}`);

  // C7 cancel is silent: no notice, no document change. The browser's own
  // cancel (interception with `cancel: true` emits the input's `cancel`
  // event); `DOM.setFileInputFiles([])` emits NOTHING (P0-3d, measured).
  mark = b.lines.length;
  const before7 = lastState();
  await b.send('Page.setInterceptFileChooserDialog', { enabled: true, cancel: true });
  await ctrlO();
  const cancel = (await b.waitFor(/^WEB-PICK cancel token=\d+ via=cancel/, DEADLINE, mark)).line;
  await b.send('Page.setInterceptFileChooserDialog', { enabled: true });
  await b.sleep(1500);
  if (b.since(mark, /^WEB-NOTICE /).length) fail('C7', `notice: ${b.since(mark, /^WEB-NOTICE /)}`);
  if (b.since(mark, /^WEB-DOC-STATE /).length) fail('C7', `state changed: ${b.since(mark, /^WEB-DOC-STATE /)}`);
  if (lastState() !== before7) fail('C7', 'state changed');
  const queue7 = [...b.lines].reverse().find(l => l.startsWith('WEB-PICK-QUEUE '));
  if (queue7 !== 'WEB-PICK-QUEUE parked=0') fail('C7', `the cancelled pick is still parked: ${queue7}`);
  ok('C7', cancel);

  // C5 broken file: a notice carrying the reader's sentence; state unchanged.
  mark = b.lines.length;
  const before5 = lastState();
  const ch5 = await openChooser();
  await b.choose(ch5, [truncated]);
  const notice = (await b.waitFor(/^WEB-NOTICE text=.*truncated\.v3d — /, DEADLINE, mark)).line;
  await b.sleep(1000);
  if (b.since(mark, /^WEB-DOC-STATE /).length || lastState() !== before5)
    fail('C5', `state changed: ${b.since(mark, /^WEB-DOC-STATE /)}`);
  ok('C5', notice);

  // C8 MEMFS cleanup (owner 2026-09-24): the cancelled pick never made a
  // directory and the refused one (C5) is already gone; opening a NEW document
  // deletes the previous document's directory and keeps the new one's.
  const dirsBefore = [...b.lines].reverse().find(l => l.startsWith('WEB-WORK-DIRS '));
  const oldDir = /docPath=\/work\/(\d+)\//.exec(lastState())[1];
  if (dirsBefore !== `WEB-WORK-DIRS dirs=${oldDir}`) fail('C8', `before the open: ${dirsBefore}`);
  mark = b.lines.length;
  const ch8 = await openChooser();
  await b.choose(ch8, [two]);
  const reopened = (await b.waitFor(new RegExp(`^WEB-DOC-STATE layers=2 verts=${V} faces=${F} images=0 docPath=/work/(\\d+)/two_layers\\.v3d dirty=0 `), DEADLINE, mark)).line;
  const newDir = /docPath=\/work\/(\d+)\//.exec(reopened)[1];
  if (newDir === oldDir) fail('C8', `the reopen reused /work/${oldDir}`);
  const swept = (await b.waitFor(new RegExp(`^WEB-WORK-DIRS dirs=${newDir}$`), DEADLINE, mark)).line;
  ok('C8', `${dirsBefore} -> ${swept}`);

  // C6 guard exactly once: dirty, then Ctrl+O. Before the choice the pathless
  // call proceeds (discards=0) and nothing prompts; after it, exactly one prompt.
  mark = b.lines.length;
  await f9();
  await b.waitFor(/^WEB-DOC-STATE .* dirty=1 /, DEADLINE, mark);
  const beforePick = b.lines.length;
  const ch6 = await openChooser();
  await b.sleep(500);
  const early = b.since(beforePick, /^WEB-GUARD /);
  if (early.length !== 1 || early[0] !== 'WEB-GUARD verdict=proceed discards=0')
    fail('C6', `before the choice: ${JSON.stringify(early)}`);
  const afterPick = b.lines.length;
  await b.choose(ch6, [two]);
  await b.waitFor(/^WEB-GUARD verdict=prompt discards=1$/, DEADLINE, afterPick);
  await b.sleep(1500);
  const prompts = b.since(beforePick, /^WEB-GUARD verdict=prompt/);
  if (prompts.length !== 1) fail('C6', `prompts: ${JSON.stringify(prompts)}`);
  ok('C6', `${early[0]} | ${prompts[0]}`);

  console.log(`WEB-FILE-IO mode=${mode} cells=${ran.join(',')} ok`);
} catch (e) {
  console.log(b.lines.slice(-40).join("\n"));
  console.log("CHOOSERS " + JSON.stringify(b.choosers));
  throw e;
} finally {
  await b.stop();
}

#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { writeFile } from 'node:fs/promises';

const [chromium, url, domPath, pngPath, profile, deadlineArg = '90000'] = process.argv.slice(2);
if (![chromium, url, domPath, pngPath, profile].every(Boolean))
  throw new Error('usage: web_cdp_capture.mjs CHROMIUM URL DOM PNG PROFILE [DEADLINE_MS]');
const deadlineMs = Number(deadlineArg);
const chrome = spawn(chromium, [
  '--headless', '--no-sandbox', '--disable-gpu', '--enable-unsafe-swiftshader',
  '--use-angle=swiftshader', '--window-size=1280,720',
  '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'
], { stdio: ['ignore', 'ignore', 'pipe'] });

let stderr = '';
let socket;
const pending = new Map();
let nextId = 1;
const stop = () => {
  try { socket?.close(); } catch {}
  if (!chrome.killed) chrome.kill('SIGTERM');
};
process.on('SIGINT', () => { stop(); process.exit(130); });
process.on('SIGTERM', () => { stop(); process.exit(143); });

try {
  const wsUrl = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`DevTools endpoint deadline; stderr=${stderr}`)), 15000);
    chrome.stderr.on('data', chunk => {
      const text = chunk.toString();
      stderr += text;
      process.stderr.write(text);
      const match = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
    chrome.once('exit', code => reject(new Error(`Chromium exited before DevTools endpoint (${code})`)));
  });
  socket = new WebSocket(wsUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (!message.id) return;
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    if (message.error) waiter.reject(new Error(JSON.stringify(message.error)));
    else waiter.resolve(message.result);
  });
  let sessionId;
  const send = (method, params = {}, useSession = true) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    const message = { id, method, params };
    if (useSession && sessionId) message.sessionId = sessionId;
    socket.send(JSON.stringify(message));
  });
  const target = await send('Target.createTarget', { url: 'about:blank' }, false);
  const attached = await send('Target.attachToTarget', {
    targetId: target.targetId, flatten: true
  }, false);
  sessionId = attached.sessionId;
  await send('Page.enable');
  await send('Runtime.enable');
  await send('Page.navigate', { url });

  const started = Date.now();
  let report = '';
  let inputSent = false;
  let inputAckAt = 0;
  let windowInputSent = false;
  let panelPressSent = false;
  let panelReleaseSent = false;
  let panelMoveSentAt = 0;
  let panelCssPoint;
  let panelReadyAt = 0;
  while (Date.now() - started < deadlineMs) {
    const result = await send('Runtime.evaluate', {
      expression: "document.querySelector('#report')?.textContent || ''",
      returnByValue: true
    });
    report = result.result?.value || '';
    if (/^ERROR |^ERR Aborted/m.test(report)) {
      const terminal = report.split('\n').filter(line =>
        /^(ERROR |ERR Aborted|OUT WEB-)/.test(line));
      throw new Error(`browser reported failure:\n${terminal.join('\n')}`);
    }
    if (!inputSent && /^OUT WEB-RUNNER-INPUT-REQUEST mouse=321,234$/m.test(report)) {
      // This crosses Chromium's native input pipeline. A DOM dispatch would
      // stay green even if the browser-to-Emscripten/SDL bridge were broken.
      await send('Input.dispatchMouseEvent', {
        type: 'mouseMoved', x: 321, y: 234, buttons: 0, pointerType: 'mouse'
      });
      inputSent = true;
    }
    if (!inputAckAt && /^OUT WEB-RUNNER-INPUT-ACK source=sdl generation=router /m.test(report))
      inputAckAt = Date.now();
    if (!windowInputSent && /^OUT WEB-RUNNER-LIVE .* context=live /m.test(report)) {
      // W16-E deliberately starts after W16-R's downstream motion witness.
      // Drive every remaining browser input family through Chromium's native
      // input domain, then resize the real canvas that SDL owns.
      await send('Input.dispatchKeyEvent', {
        type: 'keyDown', key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65,
        nativeVirtualKeyCode: 65, text: 'a', unmodifiedText: 'a'
      });
      await send('Input.dispatchKeyEvent', {
        type: 'keyUp', key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65,
        nativeVirtualKeyCode: 65
      });
      await send('Input.dispatchMouseEvent', {
        type: 'mousePressed', x: 10, y: 10, button: 'left', buttons: 1,
        clickCount: 1, pointerType: 'mouse'
      });
      await send('Input.dispatchMouseEvent', {
        type: 'mouseReleased', x: 10, y: 10, button: 'left', buttons: 0,
        clickCount: 1, pointerType: 'mouse'
      });
      await send('Input.dispatchMouseEvent', {
        type: 'mouseWheel', x: 10, y: 10, deltaX: 0, deltaY: -120,
        pointerType: 'mouse'
      });
      await send('Runtime.evaluate', {
        expression: "canvas.style.width='640px';canvas.style.height='480px';window.dispatchEvent(new Event('resize'))"
      });
      windowInputSent = true;
    }
    if (inputAckAt && Date.now() - inputAckAt > 1500
        && !/^OUT WEB-RUNNER-LIVE .* context=live /m.test(report))
      throw new Error(`downstream ImGui receipt missing after SDL/router ACK:\n${report}`);
    const panel = report.match(/^OUT WEB-PANELS-READY .* click=(\d+),(\d+)$/m);
    if (panel && !panelReadyAt) panelReadyAt = Date.now();
    if (panel && inputAckAt && !panelMoveSentAt) {
      const logicalX = Number(panel[1]);
      const logicalY = Number(panel[2]);
      const metrics = await send('Runtime.evaluate', {
        expression: `(() => { const c = document.querySelector('canvas'); const r = c.getBoundingClientRect(); return {left:r.left,top:r.top,width:r.width,height:r.height,pixelWidth:c.width,pixelHeight:c.height}; })()`,
        returnByValue: true
      });
      const m = metrics.result.value;
      const x = m.left + logicalX * m.width / m.pixelWidth;
      const y = m.top + logicalY * m.height / m.pixelHeight;
      panelCssPoint = { x, y };
      await send('Runtime.evaluate', { expression: `document.querySelector('canvas').focus()` });
      await send('Input.dispatchMouseEvent', {
        type: 'mouseMoved', x, y, buttons: 0, pointerType: 'mouse'
      });
      panelMoveSentAt = Date.now();
    }
    // Give SDL/ImGui one production frame to consume the move before the
    // press; coalescing both CDP events can otherwise hide the active frame.
    if (panelMoveSentAt && !panelPressSent && Date.now() - panelMoveSentAt >= 150) {
      const { x, y } = panelCssPoint;
      await send('Input.dispatchMouseEvent', {
        type: 'mousePressed', x, y, button: 'left', clickCount: 1
      });
      panelPressSent = true;
    }
    if (panelPressSent && !panelReleaseSent
        && /^OUT WEB-PANELS-PRESSED source=imgui-button phase=downstream-clicked /m.test(report)) {
      await send('Input.dispatchMouseEvent', {
        type: 'mouseReleased', x: panelCssPoint.x, y: panelCssPoint.y,
        button: 'left', clickCount: 1
      });
      panelReleaseSent = true;
    }
    if (panelReadyAt && Date.now() - panelReadyAt > 5000
        && !/^OUT WEB-PANELS-PRESSED /m.test(report))
      throw new Error(`production panel did not acknowledge press:\n${report}`);
    if (panelReleaseSent && Date.now() - panelReadyAt > 7000
        && !/^OUT WEB-PANELS-RELEASED /m.test(report))
      throw new Error(`production panel did not acknowledge release:\n${report}`);
    if (/^OUT WEB-WINDOW-INPUT .* resize=layout /m.test(report)
        && /^OUT WEB-PANELS-RELEASED /m.test(report)) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  if (!/^OUT WEB-WINDOW-INPUT .* resize=layout /m.test(report)
      || !/^OUT WEB-RUNNER-LIVE .* context=live /m.test(report)
      || !/^OUT WEB-PANELS-PRESSED /m.test(report)
      || !/^OUT WEB-PANELS-RELEASED /m.test(report))
    throw new Error(`browser receipt deadline after ${deadlineMs}ms:\n${report}`);

  const dom = await send('Runtime.evaluate', {
    expression: 'document.documentElement.outerHTML', returnByValue: true
  });
  const screenshot = await send('Page.captureScreenshot', { format: 'png', fromSurface: true });
  await writeFile(domPath, dom.result.value);
  await writeFile(pngPath, Buffer.from(screenshot.data, 'base64'));
} finally {
  stop();
  await new Promise(resolve => {
    if (chrome.exitCode !== null) resolve();
    else { chrome.once('exit', resolve); setTimeout(() => { chrome.kill('SIGKILL'); resolve(); }, 3000); }
  });
}

// Hand-off input from the phone, applied to the page: a one-finger drag (drag-the-shape captchas).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { CHROMIUM } from './browser-target.mjs';
import { handOff } from '../src/handoff.mjs';

test('a drag from the phone presses, moves along the path and releases on the page', async () => {
  const browser = await chromium.launch({ executablePath: CHROMIUM, headless: true });
  try {
    const context = await browser.newContext({ viewport: { width: 800, height: 400 } });
    const page = await context.newPage();
    await page.setContent(`<div id=shape style="position:absolute;left:60px;top:180px;width:40px;height:40px;background:#111"></div>
      <script>
        window.log = []; let held = false;
        shape.addEventListener('mousedown', () => { held = true; log.push('down'); });
        addEventListener('mousemove', (e) => { if (held) { shape.style.left = (e.clientX - 20) + 'px'; log.push('move'); } });
        addEventListener('mouseup', (e) => { held = false; log.push('up ' + e.clientX + ',' + e.clientY); });
      </script>`);
    let n = 0;
    const store = {
      handoffStart: async () => ({ session: 's' }),
      handoffEnd: async () => {},
      handoffFrame: async () => (++n === 1
        ? { inputs: [{ action: 'drag', points: [[0.1, 0.5], [0.5, 0.5], [0.9, 0.5]] }], done: false }
        : { inputs: [], done: true, via: 'their iPhone' }),
    };
    const r = await handOff({ context, store, reason: 'Drag the shape' });
    assert.ok(r.ok, r.message);
    const log = await page.evaluate(() => window.log);
    assert.equal(log[0], 'down');
    assert.ok(log.filter((l) => l === 'move').length >= 4, log.join(' '));
    assert.equal(log.at(-1), 'up 720,200');
    assert.equal(await page.evaluate(() => shape.style.left), '700px');
  } finally { await browser.close(); }
});

test('fast link: live press, moves and release; an unchanged page is not resent every frame', async () => {
  const browser = await chromium.launch({ executablePath: CHROMIUM, headless: true });
  try {
    const context = await browser.newContext({ viewport: { width: 800, height: 400 } });
    const page = await context.newPage();
    await page.setContent(`<div id=shape style="position:absolute;left:60px;top:180px;width:40px;height:40px;background:#111"></div>
      <script>
        window.log = []; let held = false;
        shape.addEventListener('mousedown', () => { held = true; log.push('down'); });
        addEventListener('mousemove', (e) => { if (held) shape.style.left = (e.clientX - 20) + 'px'; });
        addEventListener('mouseup', () => { held = false; log.push('up'); });
      </script>`);
    const frames = [];
    const script = [
      [{ action: 'down', x: 0.1, y: 0.5 }], [{ action: 'move', x: 0.3, y: 0.5 }], [{ action: 'move', x: 0.6, y: 0.5 }],
      [{ action: 'up', x: 0.9, y: 0.5 }], [], [], [],
    ];
    const store = {
      handoffStart: async () => ({ session: 's' }),
      handoffEnd: async () => {},
      handoffFrame: async (_s, f) => { frames.push(f.jpeg.length); const i = script.shift(); return i ? { inputs: i, done: false, fast: true } : { inputs: [], done: true }; },
    };
    const t = Date.now();
    const r = await handOff({ context, store, reason: 'Drag' });
    assert.ok(r.ok, r.message);
    assert.ok(Date.now() - t < 3000, 'fast frames, not one a second');
    assert.deepEqual(await page.evaluate(() => window.log), ['down', 'up']);
    assert.equal(await page.evaluate(() => shape.style.left), '700px');
    // After the drag the page stops changing: the last frames carry no picture.
    assert.ok(frames.at(-1) === 0 && frames.at(-2) === 0, JSON.stringify(frames));
  } finally { await browser.close(); }
});

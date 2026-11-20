// The user's own Chrome, driven through the keydillo extension: what Claude's tabs can reach, and the side doors
// that make secret steps refuse. Uses Playwright's Chromium with the extension loaded (KD_CHROMIUM to override).
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { startChrome, CHROMIUM } from './browser-target.mjs';
import { connectChrome } from '../src/chrome.mjs';

const skip = !fs.existsSync(CHROMIUM) && `Chromium not found at ${CHROMIUM}`;
const site = http.createServer((q, r) => {
  r.setHeader('content-type', 'text/html');
  if (q.url === '/set') r.setHeader('set-cookie', 'session=USER-SESSION-COOKIE; HttpOnly; Path=/');
  r.end(`<title>${q.url}</title><h1>${q.url}</h1><form action="/in" method="post"><input name="login"><input type="password" name="password"><button>Sign in</button></form>`);
}).listen(0);
const base = () => `http://127.0.0.1:${site.address().port}`;
after(() => site.close());

async function withChrome(opts, fn) {
  const c = await startChrome(opts);
  let conn;
  try { conn = await connectChrome(c.sock); await fn(conn, c); }
  finally { await conn?.browser.close().catch(() => {}); conn?.relay.close(); await c.stop(); }
}

test('Claude only sees its own tabs, and can\'t read cookies', { skip }, async () => {
  // Chrome starts with one tab of the user's own, outside Claude's group.
  await withChrome({}, async ({ context, relay }) => {
    assert.equal(context.pages().length, 0, 'the user\'s tab is invisible to Claude');
    const page = await context.newPage();
    await page.goto(`${base()}/set`); // a sign-in cookie (HttpOnly)
    await page.goto(`${base()}/claude`);
    assert.equal(await page.title(), '/claude');
    assert.equal(context.pages().length, 1);
    for (const m of ['Storage.getCookies', 'Network.getAllCookies', 'Network.getCookies', 'Network.setCookie', 'Target.getTargets', 'Target.attachToTarget', 'Browser.close', 'Page.setDownloadBehavior']) {
      await assert.rejects(relay.handle(m, {}, [...relay.sessions.values()][0].sessionId), /Refused by keydillo|Not allowed/, m);
    }
    await assert.rejects(context.cookies(), /Refused by keydillo/);
    // Same-origin page script can't read the HttpOnly cookie either, and Claude has no JavaScript tool in Chrome.
    assert.equal(await page.evaluate(() => document.cookie), '');
  });
});

test('pop-ups opened by Claude\'s tab are Claude\'s too', { skip }, async () => {
  await withChrome({}, async ({ context }) => {
    const page = await context.newPage();
    await page.goto(`${base()}/a`);
    const [popup] = await Promise.all([context.waitForEvent('page'), page.evaluate((u) => window.open(u), `${base()}/b`)]);
    // A pop-up can finish loading before keydillo attaches to it, so poll rather than wait for "load".
    let title = '';
    for (let i = 0; i < 50 && title !== '/b'; i++) { title = await popup.title().catch(() => ''); await new Promise((r) => setTimeout(r, 100)); }
    assert.equal(title, '/b');
  });
});

test('side doors: none on a normal Chrome', { skip }, async () => {
  await withChrome({}, async ({ relay }) => assert.deepEqual(await relay.sideDoors(), []));
});

test('side doors: remote debugging port', { skip }, async () => {
  await withChrome({ extraArgs: ['--remote-debugging-port=0'] }, async ({ relay }) => {
    const d = await relay.sideDoors();
    assert.ok(d.some((x) => /remote debugging/.test(x)), d.join('\n'));
  });
});

test('side doors: Allow JavaScript from Apple Events', { skip }, async () => {
  await withChrome({ prefs: { browser: { allow_javascript_apple_events: true } } }, async ({ relay }) => {
    const d = await relay.sideDoors();
    assert.ok(d.some((x) => /Apple Events/.test(x)), d.join('\n'));
  });
});

test('side doors: extensions that can read pages', { skip }, async () => {
  const fx = path.join(path.dirname(new URL(import.meta.url).pathname), 'fixtures');
  await withChrome({ extensions: [path.join(fx, 'ext-debugger'), path.join(fx, 'ext-allsites')] }, async ({ relay }) => {
    const d = await relay.sideDoors();
    assert.ok(d.some((x) => /Page Reader Agent.*debugger.*Turn it off/.test(x)), d.join('\n'));
    assert.ok(d.some((x) => /All Sites Helper.*every website.*trust it/.test(x)), d.join('\n'));
  });
});

test('fill_login and save_new_key refuse while a side door is open; browsing still works', { skip }, async () => {
  const c = await startChrome({ extraArgs: ['--remote-debugging-port=0'] });
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kdl-'));
  const log = path.join(dataDir, 'prompts.jsonl'); fs.writeFileSync(log, '');
  const client = new Client({ name: 't', version: '1' });
  await client.connect(new StdioClientTransport({
    command: process.execPath,
    args: ['src/server.mjs', '--chrome', '--chrome-socket', c.sock, '--data-dir', dataDir, '--helper', 'test/fake-helper.mjs'],
    env: { ...process.env, KDLOGIN_FAKE_SITE: base(), KDLOGIN_FAKE_LOG: log, KDLOGIN_FAKE_STATE: path.join(dataDir, 'pages.json') },
    stderr: 'inherit',
  }));
  try {
    const call = async (name, args = {}) => { const r = await client.callTool({ name, arguments: args }); return { ...r, text: r.content.map((x) => x.text).join('\n') }; };
    const nav = await call('browser_navigate', { url: `${base()}/login` });
    assert.ok(!nav.isError, nav.text);
    for (const name of ['fill_login', 'save_new_key', 'start_key_capture', 'fill_new_password']) {
      const r = await call(name, { login: 'demo', name: 'x' });
      assert.ok(r.isError); assert.match(r.text, /remote debugging/, name);
    }
    assert.equal(fs.readFileSync(log, 'utf8'), '', 'no Touch ID prompt was shown');
    const ev = await call('browser_evaluate', { function: '() => 1' });
    assert.ok(ev.isError); assert.match(ev.text, /turned off in your Chrome/);
  } finally { await client.close(); await c.stop(); }
});

test('keys are drawn as dots on screen, not just hidden from Claude', { skip }, async () => {
  const { Guard } = await import('../src/guard.mjs');
  const keysSite = http.createServer((q, r) => {
    r.setHeader('content-type', 'text/html');
    r.end(`<title>API keys</title><h1>API keys</h1><button onclick="
      document.getElementById('k').textContent = 'sk-ant-api03-' + 'Zx9'.repeat(12);
      document.getElementById('n').textContent = 'q7Lw2' + 'Hd8Vb'.repeat(5);
      document.getElementById('v').value = 'w3Rt' + 'Yp9Kz'.repeat(6);
    ">Create key</button><p>Your key: <code id="k"></code></p><p><span id="n"></span></p><input id="v" readonly><p id="plain">Keep it safe</p>`);
  }).listen(0);
  try {
    await withChrome({}, async ({ context }) => {
      const guard = new Guard({ getContext: () => context, outputDir: os.tmpdir(), chromeMode: true });
      await guard.install(context);
      const page = await context.newPage();
      await page.goto(`http://127.0.0.1:${keysSite.address().port}/keys`);
      await guard.scan(); // the API-keys page: baseline taken
      await page.click('button');
      const sec = (sel) => page.$eval(sel, (el) => getComputedStyle(el).webkitTextSecurity);
      // A known key format is dotted at once, by the page script, before Claude's next step.
      assert.equal(await sec('#k'), 'disc');
      // A key with no known format is dotted at Claude's next step, when keydillo spots it as new.
      await guard.scan();
      assert.equal(await sec('#n'), 'disc');
      assert.equal(await sec('#v'), 'disc');
      assert.equal(await sec('#plain'), 'none');
      // The page's text is unchanged, so the key can still be saved.
      assert.equal((await guard.visibleKeys()).length, 3);
    });
  } finally { keysSite.close(); }
});

test('cursor and "using this tab" pill: invisible to Claude and the page, and never in the way', { skip }, async () => {
  const s = http.createServer((q, r) => {
    r.setHeader('content-type', 'text/html');
    r.end('<meta charset=utf-8><title>t</title><body style="margin:0"><div style="text-align:center;padding:18px 0"><button id=top onclick="this.textContent=\'top clicked\'">Under the pill</button></div><button id=c onclick="this.textContent=\'Created\'">Create key</button>');
  }).listen(0);
  try {
    await withChrome({}, async ({ context, relay }) => {
      const page = await context.newPage();
      await page.goto(`http://127.0.0.1:${s.address().port}/`);
      relay.label('Clicking “Create key”');
      await page.click('#c');
      assert.equal(await page.textContent('#c'), 'Created');
      // Overlay is on the page, but its contents are out of reach of page scripts and out of Claude's snapshot.
      const seen = await page.evaluate(() => { const h = document.querySelector('keydillo-overlay'); return { host: !!h, shadow: !!h?.shadowRoot, text: document.documentElement.innerText }; });
      assert.ok(seen.host); assert.equal(seen.shadow, false); assert.ok(!seen.text.includes('using this tab'));
      assert.ok(!(await page.locator('html').ariaSnapshot()).includes('using this tab'));
      // A button right under the pill still gets Claude's click, and Claude can't press Stop.
      await page.click('#top');
      assert.equal(await page.textContent('#top'), 'top clicked');
      await page.mouse.click(400, 28);
      await new Promise((r) => setTimeout(r, 300));
      assert.equal(context.pages().length, 1, 'still Claude\'s tab');
      // Stays after a navigation.
      await page.goto(`http://127.0.0.1:${s.address().port}/next`);
      assert.ok(await page.evaluate(() => !!document.querySelector('keydillo-overlay')));
    });
  } finally { s.close(); }
});

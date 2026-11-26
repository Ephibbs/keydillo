// fill_new_password: a generated password is saved and typed into a sign-up form; Claude never sees it.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { startSite } from './site.mjs';
import { generatePassword } from '../src/signup.mjs';

let site, base, c, dataDir, log;
const call = async (name, args = {}) => {
  const r = await c.callTool({ name, arguments: args });
  return { ...r, text: (r.content || []).filter((x) => x.type === 'text').map((x) => x.text).join('\n') };
};
const entries = () => fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l));
const refOf = (snap, re) => snap.match(re)[1];

before(async () => {
  site = await startSite();
  base = `http://127.0.0.1:${site.port}`;
  dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kds-'));
  log = path.join(dataDir, 'log.jsonl'); fs.writeFileSync(log, '');
  c = new Client({ name: 't', version: '1' });
  await c.connect(new StdioClientTransport({
    command: process.execPath,
    args: ['src/server.mjs', '--headless', '--data-dir', dataDir, '--helper', 'test/fake-helper.mjs'],
    env: { ...process.env, KDLOGIN_FAKE_SITE: base, KDLOGIN_FAKE_LOG: log, KDLOGIN_FAKE_STATE: path.join(dataDir, 'pages.json') },
    stderr: 'inherit',
  }));
});
after(async () => { await c.close(); site.srv.close(); });

test('generated passwords are strong and varied', () => {
  const a = generatePassword(), b = generatePassword();
  assert.equal(a.length, 20); assert.notEqual(a, b);
  for (const re of [/[a-z]/, /[A-Z]/, /[0-9]/, /[^A-Za-z0-9]/]) assert.match(a, re);
  assert.doesNotMatch(generatePassword({ symbols: false }), /[^A-Za-z0-9]/);
});

test('needs the email typed first', async () => {
  await call('browser_navigate', { url: `${base}/signup` });
  const r = await call('fill_new_password', { login: 'acme' });
  assert.ok(r.isError); assert.match(r.text, /email or username/);
});

test('fills both fields, saves first, and Claude never sees the password', async () => {
  const snap0 = (await call('browser_snapshot')).text;
  const email = refOf(snap0, /textbox \[ref=([a-z0-9]+)\]/);
  await call('browser_type', { element: 'Email', target: email, text: 'evan@example.com' });
  const r = await call('fill_new_password', { login: 'acme' });
  assert.ok(!r.isError, r.text);
  const saved = entries().filter((e) => e.cmd === 'save-new').at(-1);
  assert.equal(saved.username, 'evan@example.com'); assert.equal(saved.site, base); assert.equal(saved.password.length, 20);
  const pw = saved.password;
  const snap = (await call('browser_snapshot')).text;
  for (const s of [r.text, snap]) assert.ok(!s.includes(pw), 'password leaked');
  assert.ok((await call('browser_evaluate', { function: '() => 1' })).isError, 'JS allowed on the sign-up page');
  const button = refOf(snap, /button "Sign in" \[ref=([a-z0-9]+)\]/);
  await call('browser_click', { element: 'Submit', target: button });
  const post = site.posts.at(-1);
  assert.equal(post.path, '/register'); assert.equal(post.f.password, pw); assert.equal(post.f.confirm, pw);
});

test('refuses a sign-up form that sends elsewhere', async () => {
  await call('browser_navigate', { url: `${base}/signup-elsewhere` });
  const r = await call('fill_new_password', { login: 'acme2', username: 'evan@example.com' });
  assert.ok(r.isError); assert.match(r.text, /different site/);
});

test('refuses a sign-in form', async () => {
  await call('browser_navigate', { url: `${base}/login` });
  const r = await call('fill_new_password', { login: 'acme3', username: 'evan' });
  assert.ok(r.isError); assert.match(r.text, /sign-in form/);
});

test('Touch ID declined: nothing is typed', async () => {
  await call('browser_navigate', { url: `${base}/signup` });
  const r = await call('fill_new_password', { login: 'denied', username: 'evan@example.com' });
  assert.ok(r.isError); assert.match(r.text, /declined/);
  assert.match((await call('browser_snapshot')).text, /textbox \[ref=[a-z0-9]+\]\n[\s\S]*textbox \[ref=[a-z0-9]+\]\n/);
});

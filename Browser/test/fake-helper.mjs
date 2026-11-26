#!/usr/bin/env node
// Stands in for bin/kdlogin in tests. No Touch ID: prompts are appended to KDLOGIN_FAKE_LOG, approved pages
// persist in KDLOGIN_FAKE_STATE, and the "user" declines any new page whose URL contains /forms/.
import fs from 'node:fs';
const site = process.env.KDLOGIN_FAKE_SITE;
const statePath = process.env.KDLOGIN_FAKE_STATE;
const logins = { demo: { username: 'evan', password: 'Hunter2-correct', totp: 'JBSWY3DPEHPK3PXP' }, wrong: { username: 'evan', password: 'Wrong-password-1' } };
const pages = fs.existsSync(statePath) ? JSON.parse(fs.readFileSync(statePath, 'utf8')) : {};
const [cmd, name, ...rest] = process.argv.slice(2);
const arg = (k) => rest[rest.indexOf(k) + 1];
if (cmd === 'save-new') {
  const password = fs.readFileSync(0, 'utf8');
  fs.appendFileSync(process.env.KDLOGIN_FAKE_LOG, JSON.stringify({ cmd, name, site: arg('--site'), username: arg('--username'), password }) + '\n');
  if (name === 'denied') { console.error('Denied.'); process.exit(2); }
  console.log('{}');
} else if (cmd === 'save-key') {
  const value = fs.readFileSync(0, 'utf8');
  fs.appendFileSync(process.env.KDLOGIN_FAKE_LOG, JSON.stringify({ cmd, name, host: arg('--host'), value }) + '\n');
  console.log('{}');
} else if (cmd === 'list') {
  console.log(JSON.stringify(Object.entries(logins).map(([n, l]) => ({ name: n, site, username: l.username, hasTotp: !!l.totp, pages: pages[n] || [] }))));
} else if ((cmd === 'get' || cmd === 'approve') && logins[name]) {
  const lp = { page: arg('--page'), action: arg('--action') };
  for (const u of [lp.page, lp.action]) if (new URL(u).origin !== site) { console.error(`${u} is not on ${site}.`); process.exit(4); }
  const known = (pages[name] || []).some((p) => p.page === lp.page && p.action === lp.action);
  fs.appendFileSync(process.env.KDLOGIN_FAKE_LOG, JSON.stringify({ cmd, name, known, ...lp }) + '\n');
  if (!known) {
    if (lp.page.includes('/forms/')) { console.error('Denied.'); process.exit(2); }
    (pages[name] ||= []).push(lp);
    fs.writeFileSync(statePath, JSON.stringify(pages));
  }
  if (cmd === 'approve') console.log('{}');
  else { const { password, totp } = logins[name]; console.log(JSON.stringify({ password, totp })); }
} else { console.error('No login'); process.exit(3); }

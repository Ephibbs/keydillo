import { execFile, spawn } from 'node:child_process';

const run = (bin, args) => new Promise((resolve, reject) => {
  execFile(bin, args, { maxBuffer: 1 << 20, timeout: 120_000 }, (err, stdout, stderr) => {
    if (err) reject(new Error(stderr.trim() || err.message)); else resolve(stdout);
  });
});

/** Talks to the kdlogin helper, which owns the Keychain items and the Touch ID prompt. */
export class Store {
  constructor(helper) { this.helper = helper; }
  /** Standalone mode has no window to show: the user adds logins in a terminal. */
  async requestLogin({ login, site }) {
    throw new Error(`Ask the user to run: bin/kdlogin add ${login || '<name>'} --site ${site || '<https://site>'}`);
  }
  async list() { return JSON.parse(await run(this.helper, ['list'])); }
  async meta(name) { return (await this.list()).find((l) => l.name === name); }
  /** Prompts Touch ID (naming the page if it's new for this login). Returns { password, totp? }. */
  async secret(name, lp) { return JSON.parse(await run(this.helper, ['get', name, '--page', lp.page, '--action', lp.action])); }
  /** Prompts Touch ID, then saves a new login whose password was generated here. Password over stdin. */
  saveNew(name, { site, username, password }) {
    return new Promise((resolve, reject) => {
      const p = spawn(this.helper, ['save-new', name, '--site', site, '--username', username], { stdio: ['pipe', 'pipe', 'pipe'] });
      let err = '';
      p.stderr.on('data', (d) => (err += d));
      p.on('close', (code) => (code === 0 ? resolve() : reject(new Error(err.trim() || `exit ${code}`))));
      p.stdin.end(password);
    });
  }
  /** Prompts Touch ID, then stores an API key bound to one host. The value goes over stdin, never argv. */
  saveKey(name, host, value) {
    return new Promise((resolve, reject) => {
      const p = spawn(this.helper, ['save-key', name, '--host', host], { stdio: ['pipe', 'pipe', 'pipe'] });
      let err = '';
      p.stderr.on('data', (d) => (err += d));
      p.on('close', (code) => (code === 0 ? resolve() : reject(new Error(err.trim() || `exit ${code}`))));
      p.stdin.end(value);
    });
  }
  /** Prompts Touch ID naming a new sign-in page, and remembers it. */
  async approve(name, lp) { await run(this.helper, ['approve', name, '--page', lp.page, '--action', lp.action]); }
}

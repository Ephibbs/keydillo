// keydillo's native messaging host. Chrome starts it for the keydillo extension and talks to it over stdin/stdout
// (4-byte length + JSON). keydillo's browser tool connects to it over a Unix socket only you can open, and the host
// passes messages between the two. It also answers `host.sideDoors`: ways into this Chrome that bypass keydillo.
//
// No password or key ever passes through here: the browser tool gets those from the keydillo app directly.

import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';

export const SOCKET = process.env.KEYDILLO_CHROME_SOCKET || path.join(os.homedir(), 'Library/Application Support/keydillo/chrome/bridge.sock');

/** Chrome's command line, from the host's parent process (Chrome starts the host itself). */
function chromeArgs(pid = process.ppid) {
  try { return execFileSync('/bin/ps', ['-o', 'command=', '-p', String(pid)], { encoding: 'utf8' }).trim(); } catch { return ''; }
}

function userDataDir(args) {
  const m = args.match(/--user-data-dir=("[^"]+"|\S+)/);
  if (m) return m[1].replace(/^"|"$/g, '');
  const base = /Chromium\.app/.test(args) ? 'Chromium' : /Chrome Canary/.test(args) ? 'Google/Chrome Canary' : /Chrome Beta/.test(args) ? 'Google/Chrome Beta' : 'Google/Chrome';
  return path.join(os.homedir(), 'Library/Application Support', base);
}

/** Every way found to read or drive this Chrome without going through keydillo. Empty means none. */
export function sideDoors(args = chromeArgs()) {
  const doors = [];
  if (/--remote-debugging-(port|pipe|address)/.test(args)) {
    doors.push('Chrome was started with a remote debugging port, so any program can control it. Quit Chrome and open it normally.');
  }
  const dir = userDataDir(args);
  if (fs.existsSync(path.join(dir, 'DevToolsActivePort')) && !doors.length) {
    doors.push('Chrome has a remote debugging port open (DevToolsActivePort exists). Quit Chrome and open it normally.');
  }
  let profiles = [];
  try { profiles = fs.readdirSync(dir).filter((d) => d === 'Default' || /^Profile \d+$/.test(d)); } catch {}
  for (const p of profiles) {
    try {
      const prefs = JSON.parse(fs.readFileSync(path.join(dir, p, 'Preferences'), 'utf8'));
      if (prefs?.browser?.allow_javascript_apple_events === true) {
        doors.push('"Allow JavaScript from Apple Events" is on, so any script can read pages. Turn it off in Chrome: View → Developer.');
        break;
      }
    } catch {}
  }
  return doors;
}

function main() {
  fs.mkdirSync(path.dirname(SOCKET), { recursive: true, mode: 0o700 });
  fs.chmodSync(path.dirname(SOCKET), 0o700);
  let client = null;

  const toChrome = (obj) => {
    const b = Buffer.from(JSON.stringify(obj));
    const h = Buffer.alloc(4); h.writeUInt32LE(b.length);
    process.stdout.write(Buffer.concat([h, b]));
  };
  let buf = Buffer.alloc(0);
  process.stdin.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    while (buf.length >= 4) {
      const n = buf.readUInt32LE(0);
      if (buf.length < 4 + n) break;
      const m = buf.subarray(4, 4 + n).toString();
      buf = buf.subarray(4 + n);
      client?.write(m + '\n');
    }
  });
  process.stdin.on('end', () => { try { fs.unlinkSync(SOCKET); } catch {} process.exit(0); });

  try { fs.unlinkSync(SOCKET); } catch {}
  const server = net.createServer((c) => {
    if (client) { c.end(JSON.stringify({ error: 'Another keydillo browser tool is already using this Chrome.' }) + '\n'); return; }
    client = c;
    let line = '';
    c.on('data', (d) => {
      line += d;
      let i;
      while ((i = line.indexOf('\n')) >= 0) {
        const raw = line.slice(0, i); line = line.slice(i + 1);
        if (!raw) continue;
        let m; try { m = JSON.parse(raw); } catch { c.destroy(); return; }
        if (m.method === 'host.sideDoors') c.write(JSON.stringify({ id: m.id, result: sideDoors() }) + '\n');
        else toChrome(m);
      }
    });
    c.on('close', () => { if (client === c) { client = null; toChrome({ method: 'client.bye' }); } });
    c.on('error', () => {});
    toChrome({ method: 'client.hello' });
  });
  server.listen(SOCKET, () => fs.chmodSync(SOCKET, 0o600));
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(new URL(import.meta.url).pathname)) main();

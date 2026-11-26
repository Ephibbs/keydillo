// Which browser the end-to-end tests drive. Default: a browser the tool launches itself (--headless).
// KD_CHROME=1: a Chromium with the keydillo extension loaded, driven through the extension (--chrome),
// the way the tool drives the user's own Chrome.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { install } from '../chrome/install.mjs';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
// Playwright's own Chromium (any installed version): it can load an unpacked extension from the command line.
function findChromium() {
  const cache = path.join(os.homedir(), 'Library/Caches/ms-playwright');
  let dirs = [];
  try { dirs = fs.readdirSync(cache).filter((d) => /^chromium-\d+$/.test(d)).sort((a, b) => b.split('-')[1] - a.split('-')[1]); } catch {}
  for (const d of dirs) {
    for (const rel of ['chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing', 'chrome-mac/Chromium.app/Contents/MacOS/Chromium']) {
      const p = path.join(cache, d, rel);
      if (fs.existsSync(p)) return p;
    }
  }
  return path.join(cache, 'chromium/missing');
}
export const CHROMIUM = process.env.KD_CHROMIUM || findChromium();
export const chromeMode = process.env.KD_CHROME === '1';

/** Starts Chromium with the keydillo extension (and any extra extensions). Returns the socket and a stop function. */
export async function startChrome({ extraArgs = [], extensions = [], prefs } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kdc-'));
  const udd = path.join(dir, 'udd');
  install({ userDataDir: udd, support: dir });
  if (prefs) { fs.mkdirSync(path.join(udd, 'Default'), { recursive: true }); fs.writeFileSync(path.join(udd, 'Default', 'Preferences'), JSON.stringify(prefs)); }
  const sock = path.join(dir, 'b.sock');
  const exts = [path.join(root, 'chrome/extension'), ...extensions].join(',');
  const proc = spawn(CHROMIUM, [`--user-data-dir=${udd}`, `--load-extension=${exts}`, '--headless=new', '--no-first-run', '--no-default-browser-check', '--use-mock-keychain', '--password-store=basic', ...extraArgs, 'about:blank'], {
    env: { ...process.env, KEYDILLO_CHROME_SOCKET: sock }, stdio: 'ignore',
  });
  for (let i = 0; i < 300 && !fs.existsSync(sock); i++) await new Promise((r) => setTimeout(r, 100));
  if (!fs.existsSync(sock)) { proc.kill(); throw new Error('The keydillo extension did not start its native host'); }
  return { sock, udd, proc, stop: async () => { proc.kill(); await new Promise((r) => proc.once('exit', r)); fs.rmSync(dir, { recursive: true, force: true }); } };
}

export async function browserArgs() {
  if (!chromeMode) return { args: ['--headless'], stop: async () => {} };
  const c = await startChrome();
  return { args: ['--chrome', '--chrome-socket', c.sock], stop: c.stop };
}

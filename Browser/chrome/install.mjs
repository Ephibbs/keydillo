#!/usr/bin/env node
// Registers keydillo's native messaging host with Chrome, so the keydillo extension can reach the browser tool.
//   node chrome/install.mjs                     your normal Chrome (and Chromium, Beta, Canary if installed)
//   node chrome/install.mjs --user-data-dir D   a Chrome started with --user-data-dir D (tests)
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const HOST_NAME = 'com.studiokillswitch.keydillo';
export const EXTENSION_ID = 'cdhhnnnkegdlahpggglimplmchmahadb';

const here = path.dirname(fileURLToPath(import.meta.url));

export function install({ userDataDir, node = process.execPath, extensionIds = [EXTENSION_ID], support = path.join(os.homedir(), 'Library/Application Support/keydillo/chrome') } = {}) {
  // Chrome starts the host with almost no environment, so the wrapper names node by full path.
  fs.mkdirSync(support, { recursive: true, mode: 0o700 });
  const wrapper = path.join(support, 'keydillo-chrome-host');
  fs.writeFileSync(wrapper, `#!/bin/sh\nexec "${node}" "${path.join(here, 'host.mjs')}" "$@"\n`, { mode: 0o755 });
  const manifest = {
    name: HOST_NAME,
    description: 'keydillo browser tool bridge',
    path: wrapper,
    type: 'stdio',
    allowed_origins: extensionIds.map((id) => `chrome-extension://${id}/`),
  };
  const lib = path.join(os.homedir(), 'Library/Application Support');
  const dirs = userDataDir
    ? [userDataDir]
    : ['Google/Chrome', 'Chromium', 'Google/Chrome Beta', 'Google/Chrome Canary'].map((d) => path.join(lib, d)).filter((d) => d.endsWith('Google/Chrome') || fs.existsSync(d));
  const written = [];
  for (const d of dirs) {
    const f = path.join(d, 'NativeMessagingHosts', `${HOST_NAME}.json`);
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, JSON.stringify(manifest, null, 2));
    written.push(f);
  }
  return written;
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const i = process.argv.indexOf('--user-data-dir');
  for (const f of install({ userDataDir: i > 0 ? process.argv[i + 1] : undefined })) console.log('Registered', f);
  console.log(`\nNow load the extension: chrome://extensions → Developer mode → Load unpacked → ${path.join(here, 'extension')}`);
  console.log(`Its ID should be ${EXTENSION_ID}.`);
}

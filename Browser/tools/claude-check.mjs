// Does Claude Code call fill_login? Starts the local test site, then runs `claude -p` with this MCP server
// (fake helper, no Touch ID) and prints which tools it called and its final answer.
import { startSite } from '../test/site.mjs';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const site = await startSite();
const base = `http://127.0.0.1:${site.port}`;
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kdl-claude-'));
const cfg = path.join(dir, 'mcp.json');
fs.writeFileSync(cfg, JSON.stringify({ mcpServers: { kdlogin: {
  command: process.execPath,
  args: [path.resolve('src/server.mjs'), '--headless', '--data-dir', dir, '--helper', path.resolve('test/fake-helper.mjs')],
  env: { KDLOGIN_FAKE_SITE: base, KDLOGIN_FAKE_LOG: path.join(dir, 'log.jsonl'), KDLOGIN_FAKE_STATE: path.join(dir, 'pages.json') },
} } }));
const prompt = process.argv[2] ? process.argv[2].replaceAll('BASE', base) : `Log in to my account at ${base}/login and tell me what the page says after signing in.`;
const p = spawn('claude', ['-p', prompt, '--mcp-config', cfg, '--strict-mcp-config', '--output-format', 'stream-json', '--verbose',
  '--allowedTools', 'mcp__kdlogin__*'], { stdio: ['ignore', 'pipe', 'inherit'] });
let buf = '';
p.stdout.on('data', (d) => {
  buf += d; let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    try {
      const m = JSON.parse(line);
      for (const c of m.message?.content ?? []) if (c.type === 'tool_use') console.log('TOOL', c.name, JSON.stringify(c.input));
      if (m.type === 'result') console.log('RESULT', m.result);
    } catch {}
  }
});
p.on('close', () => { console.log('POSTS', JSON.stringify(site.posts.map((x) => x.path))); site.srv.close(); });

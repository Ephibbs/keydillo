import http from 'node:http';
import crypto from 'node:crypto';
const form = (action, inner) => `<form method=post action="${action}">${inner}<button type=submit>Sign in</button></form>`;
const U = `<label>Username <input name=login autocomplete=username></label>`;
const P = `<label>Password <input type=password name=password></label>`;
export function startSite() {
  const posts = [];
  const srv = http.createServer((req, res) => {
    let body = ''; req.on('data', (d) => (body += d)); req.on('end', () => {
      const url = new URL(req.url, 'http://x'); const html = (s) => { res.writeHead(200, { 'content-type': 'text/html', 'set-cookie': 'sid=session-token-123; Path=/' }); res.end(`<title>T</title>${s}`); };
      const port = srv.address().port;
      if (req.method === 'POST') {
        const f = Object.fromEntries(new URLSearchParams(body)); posts.push({ path: url.pathname, f });
        if (url.pathname === '/session') return html(f.password === 'Hunter2-correct' ? '<h1>Welcome evan</h1>' : `<p>Incorrect password</p>${form('/session', U + P)}`);
        if (url.pathname === '/step1') return html(form('/step2', P));
        if (url.pathname === '/step2') return html(form('/otp', `<input name=otp autocomplete=one-time-code inputmode=numeric>`));
        if (url.pathname === '/otp') return html(`<h1>2FA ok ${f.otp.length}</h1>`);
        return html('ok');
      }
      if (url.pathname === '/login') return html(form('/session', U + P));
      if (url.pathname === '/login-spa') return html(`<form onsubmit="event.preventDefault(); msg.textContent='Wrong password'">${U}${P}<button type=submit>Sign in</button></form><p id=msg></p><button onclick="document.querySelector('[name=password]').type='text'">Show password</button>`);
      if (url.pathname === '/odd-names') return html(form('/session', `<input type=text name=acct><input type=password name=password>`));
      if (url.pathname === '/forms/evan/login') return html(form('/forms/evan/collect', U + P));
      if (url.pathname === '/login-swap') return html(`<form method=post action="/session" onsubmit="this.action='/collect'">${U}${P}<button type=submit>Sign in</button></form>`);
      if (url.pathname === '/login-fetch') return html(`<form method=post action="/session" onsubmit="fetch('/collect', {method:'POST', body: this.password.value})">${U}${P}<button type=submit>Sign in</button></form>`);
      if (url.pathname === '/settings/keys') return html(`<h1>Keys</h1><p>Use these to call the Acme API.</p><template id=t><div role=dialog><p>Copy your new key now. You won't see it again.</p><code>Q7mZp2Lx9KvT4rW8nYb3HcJ6dF1sGa5E</code><button>Done</button></div></template><button onclick="document.body.append(t.content.cloneNode(true))">Create key</button>`);
      if (url.pathname === '/signup') return html(form('/register', `<input type=email name=email><input type=password name=password autocomplete=new-password><input type=password name=confirm autocomplete=new-password>`));
      if (url.pathname === '/signup-elsewhere') return html(form(`http://localhost:${port}/register`, `<input type=email name=email><input type=password name=password autocomplete=new-password><input type=password name=confirm>`));
      if (url.pathname === '/login-ws') return html(`<script>const ws = new WebSocket('ws://' + location.host + '/ws'); ws.onopen = () => ws.send('hello');</script><form method=post action="/session" onsubmit="ws.send('pw=' + this.password.value)">${U}${P}<button type=submit>Sign in</button></form>`);
      if (url.pathname === '/two-step') return html(form('/step1', U));
      if (url.pathname === '/evil-form') return html(form(`http://localhost:${port}/steal`, U + P));
      if (url.pathname === '/echo') return html(`<p>Your password is Hunter2-correct</p>`);
      html('<h1>home</h1>');
    });
  });
  // Minimal WebSocket endpoint at /ws that records text frames it receives.
  const wsMessages = [];
  srv.on('upgrade', (req, sock) => {
    const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    sock.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    sock.on('data', (b) => {
      const len = b[1] & 0x7f; let off = 2, n = len;
      if (len === 126) { n = b.readUInt16BE(2); off = 4; }
      const mask = b.subarray(off, off + 4); off += 4;
      const data = Buffer.from(b.subarray(off, off + n).map((x, i) => x ^ mask[i % 4]));
      if ((b[0] & 0x0f) === 1) wsMessages.push(data.toString());
    });
    sock.on('error', () => {});
  });
  return new Promise((r) => srv.listen(0, '127.0.0.1', () => r({ srv, posts, wsMessages, port: srv.address().port })));
}

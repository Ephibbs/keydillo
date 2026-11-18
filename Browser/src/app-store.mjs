import net from 'node:net';

/**
 * Store backed by the keydillo app. The app started this process and holds the other end of fd 3, a private
 * socketpair: passwords come only over it, after Touch ID in the app. Nothing else can ask the app for them.
 */
export class AppStore {
  constructor(fd = 3) {
    this.next = 1;
    this.pending = new Map();
    this.sock = new net.Socket({ fd, readable: true, writable: true });
    let buf = '';
    this.sock.on('data', (d) => {
      buf += d.toString('utf8');
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i); buf = buf.slice(i + 1);
        let msg; try { msg = JSON.parse(line); } catch { continue; }
        const p = this.pending.get(msg.id);
        if (!p) continue;
        this.pending.delete(msg.id);
        msg.ok ? p.resolve(msg.result) : p.reject(new Error(msg.error || 'failed'));
      }
    });
    // Without the app there is nothing to protect or serve.
    this.sock.on('close', () => process.exit(0));
  }

  call(op, args = {}) {
    const id = this.next++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.sock.write(JSON.stringify({ id, op, ...args }) + '\n');
    });
  }

  list() { return this.call('list'); }
  async meta(name) { return (await this.list()).find((l) => l.name === name); }
  secret(name, lp) { return this.call('secret', { login: name, page: lp.page, action: lp.action }); }
  approve(name, lp) { return this.call('approvePage', { login: name, page: lp.page, action: lp.action }); }
  saveNew(name, { site, username, password }) { return this.call('saveNew', { login: name, site, username, password }); }
  requestLogin({ login, site, username }) { return this.call('requestLogin', { login, site, username }); }
  async saveKey(name, host, value, extra = {}) { return (await this.call('saveKey', { name, host, value, ...extra })).placeholder; }
}

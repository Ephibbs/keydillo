// Line-based HTTP driver for Node: node driver.mjs <fetch|axios|undici|http>
import readline from "node:readline";
const lib = process.argv[2];
const out = (o) => process.stdout.write(JSON.stringify(o) + "\n");

async function run(r) {
  const body = r.body_b64 ? Buffer.from(r.body_b64, "base64") : undefined;
  const t0 = Date.now(); let ttfb = null;
  if (lib === "fetch" || lib === "undici") {
    const f = lib === "fetch" ? fetch : (await import("undici")).fetch;
    let b = body;
    const init = { method: r.method, headers: r.headers || {}, redirect: "manual" };
    if (body && r.chunked) {
      init.body = new ReadableStream({ start(c) { for (let i = 0; i < body.length; i += 65536) c.enqueue(body.subarray(i, i + 65536)); c.close(); } });
      init.duplex = "half";
    } else if (body) init.body = b;
    const res = await f(r.url, init);
    const chunks = [];
    if (res.body) for await (const c of res.body) { if (ttfb === null) ttfb = (Date.now() - t0) / 1000; chunks.push(Buffer.from(c)); }
    return out({ status: res.status, headers: [...res.headers.entries()], body_b64: Buffer.concat(chunks).toString("base64"), ttfb, total: (Date.now() - t0) / 1000 });
  }
  if (lib === "axios") {
    const axios = (await import("axios")).default;
    const res = await axios.request({ url: r.url, method: r.method, headers: r.headers || {}, data: body, responseType: "stream",
      maxRedirects: 0, validateStatus: () => true, proxy: false, maxBodyLength: Infinity, maxContentLength: Infinity, decompress: true });
    const chunks = [];
    for await (const c of res.data) { if (ttfb === null) ttfb = (Date.now() - t0) / 1000; chunks.push(Buffer.from(c)); }
    return out({ status: res.status, headers: Object.entries(res.headers).map(([k, v]) => [k, String(v)]), body_b64: Buffer.concat(chunks).toString("base64"), ttfb, total: (Date.now() - t0) / 1000 });
  }
}

const rl = readline.createInterface({ input: process.stdin });
for await (const line of rl) {
  try { await run(JSON.parse(line)); } catch (e) { out({ status: 0, headers: [], body_b64: "", error: `${e.name}: ${e.message}${e.cause ? " (" + e.cause.message + ")" : ""}` }); }
}


const which = process.argv[2]; const base = process.argv[3];
try {
  if (which === "openai") { const { default: OpenAI } = await import("openai");
    const o = new OpenAI({ apiKey: "keydillo:openai", baseURL: base + "/openai/v1" });
    const r = await o.chat.completions.create({ model: "m", messages: [{ role: "user", content: "hi" }] });
    let s = ""; for await (const ch of await o.chat.completions.create({ model: "m", messages: [], stream: true })) s += ch.choices[0]?.delta?.content || "";
    console.log(JSON.stringify({ ok: r.choices[0].message.content === "Hello" && s === "Hello" }));
  } else if (which === "anthropic") { const { default: A } = await import("@anthropic-ai/sdk");
    const a = new A({ apiKey: "keydillo:anthropic", baseURL: base + "/anthropic" });
    const r = await a.messages.create({ model: "m", max_tokens: 5, messages: [{ role: "user", content: "hi" }] });
    let s = ""; const st = await a.messages.create({ model: "m", max_tokens: 5, messages: [{ role: "user", content: "hi" }], stream: true });
    for await (const e of st) if (e.type === "content_block_delta") s += e.delta.text;
    console.log(JSON.stringify({ ok: r.content[0].text === "Hello" && s === "Hello" }));
  } else if (which === "stripe") { const { default: Stripe } = await import("stripe");
    // Stripe's SDK can't add a path prefix, so point it at a per-service port-less host via a custom HTTP client.
    const u = new URL(base);
    const http = await import("node:http");
    const agent = new http.Agent();
    const client = Stripe.createNodeHttpClient(agent);
    const orig = client.makeRequest.bind(client);
    client.makeRequest = (host, port, path, ...rest) => orig(u.hostname, u.port, "/stripe" + path, ...rest);
    const s = new Stripe("keydillo:stripe", { httpClient: client, host: u.hostname, port: u.port, protocol: "http" });
    const r = await s.customers.list(); console.log(JSON.stringify({ ok: r.object === "list" }));
  } else if (which === "ws") { const { default: WebSocket } = await import("ws");
    const ws = new WebSocket(base.replace("http", "ws") + "/hdr/ws");
    ws.on("open", () => ws.send("ping")); ws.on("message", (m) => { const j = JSON.parse(m); console.log(JSON.stringify({ ok: j.echo === "ping", auth: j.auth })); ws.close(); });
    ws.on("error", (e) => console.log(JSON.stringify({ ok: false, error: e.message })));
  }
} catch (e) { console.log(JSON.stringify({ ok: false, error: e.message })); }

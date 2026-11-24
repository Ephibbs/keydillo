<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/wordmark-white.svg">
    <img src="docs/assets/wordmark.svg" alt="keydillo" width="260">
  </picture>
</p>

<h3 align="center">Let AI use your keys without seeing them</h3>

<p align="center">Don’t let AI expose your secrets.<br />Get set up in seconds and forget about it.</p>

<p align="center"><img src="docs/assets/demo.gif" alt="Claude Code needs an ElevenLabs key, keydillo opens a window where the key is pasted, the .env gets a placeholder, and after Touch ID the voiceover is saved" width="760"></p>

<p align="center"><a href="https://ephibbs.github.io/keydillo-site/">Website</a> · <a href="#install">Install</a> · <a href="SECURITY.md">Security</a> · <a href="docs/roadmap.md">Roadmap</a></p>

keydillo is a free, open-source Mac menu-bar app. Your API keys stay in the Keychain, behind Touch ID. Claude Code and your programs only get placeholders, and keydillo adds the real key at transport-time and only to that key's host.

No account, no cloud, no telemetry. MIT licensed.

## How it works

1. **Your keys live in the Mac Keychain, not in .env files.** keydillo imports them, and your .env gets replaced with placeholders like `OPENAI_API_KEY=keydillo:openai:start-with-keydillo-run`. If Claude reads the file, the placeholder is all it sees.
2. **Run your app with `kd`.** `kd npm run dev` sends your app's API calls through a small proxy that runs only on your Mac. Don't worry. Claude will run it without you asking.
3. **The proxy swaps in the real key at the last moment.** When a request leaves for api.openai.com, keydillo replaces the placeholder with the real key, and only for the site that key belongs to. The key never shows up in your code, terminal, logs or Claude's context!
4. **You approve with Touch ID.** The first time a key is used, you get a prompt naming the app and the site. Approve once per session, or turn on "don't ask again".

## What keydillo protects against, and what it doesn't

| | | Notes |
|---|---|---|
| ✅ | AI agents never see your real keys | Your `.env` only holds `keydillo:<name>` placeholders. |
| ✅ | Committing `.env` to GitHub leaks nothing | Only the placeholder is in the file. |
| ✅ | Keys stay out of chats, transcripts and logs | Agents never get the value, and keydillo scrubs it from responses. |
| ✅ | Other apps can't read your keys from the Keychain | They sit in a private Keychain group only keydillo's signed app can open, behind Touch ID. |
| ✅ | Keys only go to their own site | Sending one to a new host needs your Touch ID. |
| ✅ | Web pages can't use your keys through the proxy | Cross-site browser requests are refused. |
| ⚠️ | Launch-time keys are hidden from files, but the program you start can read them | Database URLs, JWT secrets and the like. A database proxy is on the [roadmap](docs/roadmap.md). |
| ❌ | Doesn't stop a program you approved from misusing the key | keydillo guards the key, not what's done with it at the provider. |
| ❌ | Doesn't protect keys in deployed frontend code | keydillo works on your Mac, not in production. |
| ❌ | Doesn't protect copies made before you installed it | Old `.env` files, shell and git history. Rotate those keys. |

Good to know:
- Your Mac's login password can stand in for Touch ID, so anyone who knows it can approve.
- With "Once per session", a program you approved can keep *using* a key without new prompts. It still can't *read* it. Parallel calls within 3 seconds of an approval share it.
- "Ask once per project" trusts any program you run in that project's folder. Use it for keys that can't cost much.
- The Claude Code hook steers agents to keydillo. It isn't a security barrier.
- Go, Rust, gRPC and edge middleware ignore kd's certificate, so `kd` can't add keys for them. Call the key's local base URL instead. More in [docs/kd-known-failures.md](docs/kd-known-failures.md).

More detail in [Security model and limits](#security-model-and-limits).

## Install

```sh
brew install --cask ephibbs/keydillo/keydillo
```

Then open keydillo and choose **Connect** in its setup. That sets up Claude Code, Cursor and Codex (whichever you have): keydillo's tools, the skill, and the check that puts `kd` in front of commands. Codex asks you to trust new checks once: type `/hooks` in Codex and trust keydillo's. Codex's sandbox blocks keydillo, so Codex asks you before running a `kd` command outside it.

Or [download the zip](https://github.com/Ephibbs/keydillo/releases/latest) (signed and notarized, macOS 15+), unzip it and move keydillo to Applications.

**Claude Code plugin** (instead of Connect):

```
/plugin marketplace add Ephibbs/keydillo
/plugin install keydillo@keydillo
```

**Skill only**, for other coding agents: `npx skills add Ephibbs/keydillo`. This adds the instructions but not the check before commands, so prefer Connect for Claude Code, Cursor and Codex.

**Build from source** (macOS 15+, Xcode 16, [XcodeGen](https://github.com/yonaskolb/XcodeGen), an Apple Developer account):

```sh
git clone https://github.com/Ephibbs/keydillo
cd keydillo/App
# set DEVELOPMENT_TEAM in project.yml to your team ID
xcodegen
open Keydillo.xcodeproj
```

Keys are stored in a private Keychain group tied to your team, so the Mac you build on must be registered in your developer account. Builds without that group refuse to store keys.

---

## Using your keys

**Put `kd` in front of commands that use your keys. Claude does it for you.**

- `kd npm run dev` (short for `keydillo run -- npm run dev`) runs the command with its HTTPS going through a
  small proxy that only that command and its child processes can use. When a program sends a
  `keydillo:<name>` placeholder to its API, keydillo asks for Touch ID and swaps in the real key. Everything
  else passes through untouched, still encrypted. `kd` is installed in `~/.local/bin`, next to `claude`.
- Claude Code (with the keydillo plugin, or after "Connect" in keydillo) is told to put `kd` in front of
  commands that call APIs. Nothing is routed without `kd`.
- If keydillo isn't running, `kd` opens it in the background (unless you quit it yourself from the menu).
- To stop using keydillo for a project or everything, use **Put my real keys back** (menu bar or Settings). Each import also saves a copy of the original .env files in keydillo's private Keychain group, as a safety net.
- If an API still says the key is invalid, the program skipped keydillo (see the limits below). Claude is told
  this right after the command; the fix is to call the API through its `*_BASE_URL`
  (`http://localhost:7787/<name>/...`).

Tested with curl, Python (`requests`, `httpx`, `aiohttp`, `urllib`), Node (`fetch`, `https`, `undici`, axios),
Bun and Deno. Results: `tests/compat/REPORT.md`.

## Credits

Service logos are from [Simple Icons](https://simpleicons.org) (CC0-1.0). Logos are trademarks of their owners and are used only to identify each service.

## Privacy

keydillo has **no telemetry**: no analytics, no crash reporting, no update pings. Nothing leaves your Mac except the
API requests you approve, sent straight to the provider you configured.

## Security model and limits

keydillo is responsible for keys **while it's installed**. Copies that existed before you installed it (old
`.env` files, shell history, git history, provider dashboards, chat transcripts) and copies you make yourself
afterwards (the Readout, Show key) are outside what it can protect.

Details:
- **Keychain:** keys live in a private access group only keydillo's signed binary can use, and reading one needs Touch ID. `security find-generic-password` and other apps can't see them.
- **Proxy:** agents get local addresses and placeholders. The proxy adds the key on the way out, only to that key's host. Requests with a non-localhost Host header or from another site are refused.
- **Scrubbing** is best effort: it removes the forms of the key keydillo produced (raw, Basic, base64, percent-encoded), not ones a provider transforms other ways. That's why each key goes only in its one configured spot unless you turn on "Allow the key anywhere". Without it, a key the API wants in the body, query or path is refused with `placeholder_misplaced`.
- **Locked Mac:** keys can't be read, and requests get a "Mac is locked" reply. "Ask once per project" keys stay in keydillo's memory (locked into RAM, zeroed when dropped) after one Touch ID, and keep working until keydillo quits.
- **Launch-time keys** cover secrets your app uses itself (database URLs, JWT, session, encryption and webhook signing keys, AWS/Cloudinary signing keys, service-account files). The `.env` keeps a random placeholder, and `kd` hands over the real value at start after a Touch ID that names the command, every time. They're unticked at import.
- **Not under `kd` yet:** programs started with a cleaned environment, Python with `-I`, Docker with `--env-file` (use `http://host.docker.internal:7787/<name>`), and SDKs that check a key's format at startup, like Clerk.
- **Builds** without the private Keychain group refuse to store keys.

Report vulnerabilities privately: see [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).

keydillo is not affiliated with Anthropic.

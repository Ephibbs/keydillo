<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/wordmark-white.svg">
    <img src="docs/assets/wordmark.svg" alt="keydillo" width="260">
  </picture>
</p>

<p align="center">Let AI use your keys without seeing them.</p>

<p align="center"><img src="docs/assets/demo.gif" alt="Claude Code runs kd python voiceover.py, keydillo asks for Touch ID to use the ElevenLabs key, and the voiceover is saved" width="760"></p>

<p align="center"><a href="https://ephibbs.github.io/keydillo-site/">Website</a> · <a href="#install">Install</a> · <a href="SECURITY.md">Security</a> · <a href="docs/roadmap.md">Roadmap</a></p>

keydillo is a free, open-source Mac menu-bar app. Your API keys stay in the Keychain, behind Touch ID. Claude Code and your programs only get placeholders, and keydillo adds the real key on the way out, only to that key's host.

No account, no cloud, no telemetry. MIT licensed.

## How it works

1. Install keydillo and connect Claude.
2. Import your `.env`. Keys become placeholders.
3. Ask Claude to run it. It adds `kd`.
4. Approve with Touch ID.
5. The real API key goes out. Claude never sees it.

The rule: **put `kd` in front. Claude does it for you.**

```sh
kd npm run dev
```

## What it protects

| Protects | Doesn't protect |
|---|---|
| API keys out of prompts, transcripts and `.env` files | Launch-time keys (database URLs, JWT and encryption secrets) once your app is running |
| Keys at rest, behind Touch ID | What an agent does with access you approve |
| Keys sent to the wrong host | Copies made before you installed it |

Launch-time keys are handed to your program as it starts, so a command that prints its environment could show them. A local database proxy that keeps passwords out of the program is first on the [roadmap](docs/roadmap.md). Where `kd` can fail today: [docs/kd-known-failures.md](docs/kd-known-failures.md).

## Install

A signed, notarized download is coming soon. Until then you can build it yourself.

**Build from source** (macOS 15+, Xcode 16, [XcodeGen](https://github.com/yonaskolb/XcodeGen), an Apple Developer account):

```sh
git clone https://github.com/Ephibbs/keydillo
cd keydillo/App
# set DEVELOPMENT_TEAM in project.yml to your team ID
xcodegen
open Keydillo.xcodeproj
```

Keys are stored in a private Keychain group tied to your team, so the Mac you build on must be registered in your developer account. Builds without that group refuse to store keys.

**Claude Code plugin:**

```
/plugin marketplace add Ephibbs/keydillo
/plugin install keydillo@keydillo
```

Or click Connect in keydillo.

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

What it does protect while installed:
- Keys live in a private Keychain access group that only keydillo's signed binary can use, with Touch ID required to read them. `security find-generic-password` and other apps can't see them.
- Agents only get local addresses and `keydillo:<name>` placeholders. The proxy adds the key on the way out, only to that key's host, and scrubs the key from responses.
- Web pages can't use keydillo: cross-site browser requests and non-localhost Host headers are refused.

Known limits, in scope:
- macOS lets your login password stand in for Touch ID. Anyone who knows it can approve requests.
- During an approval window (e.g. "every 15 minutes" or "once per session"), a program can *use* the key through the proxy without a new prompt. It still can't *read* the key.
- Parallel calls from the same program within 3 seconds of an approval share it, instead of prompting once per call.
- A program you approve can do anything that key allows with the provider. keydillo guards the key, not what you do with it.
- Response scrubbing is best effort: keydillo removes the forms of the key it produced itself (raw, Basic, base64, percent-encoded), but can't catch a provider that transforms a key in other ways. That's why each key is only ever placed in its one configured spot unless you opt in.
- The Claude Code hook is guidance that steers agents to keydillo, not a security barrier.
- Builds without a private Keychain access group refuse to store keys.
- While the Mac is locked, keys can't be read from the Keychain and requests get a clear "Mac is locked" reply,
  except for projects set to "Ask once per project": after one Touch ID those keys are held in keydillo's memory
  (locked into RAM, zeroed when dropped) and keep working while the Mac is locked, until keydillo quits.
- "Ask once per project" trusts programs by their working folder. Any program you run that changes into that folder
  can use the project's keys without a prompt. Use it only for projects whose keys can't cost much.

What doesn't work yet (use the local base URL instead, or keep that key out of keydillo):
- A key the API wants in the body, query or path is refused with `placeholder_misplaced` unless you turn on "Allow the key anywhere" for that key.
- Secrets your app uses itself (database URLs, JWT, session, encryption and webhook signing keys) can be imported as **launch-time keys**: the .env keeps a random placeholder and `kd` gives the real value to the program as it starts, after a Touch ID prompt that names the command (every time; project and session approvals don't cover these). They are **not fully hidden**: anything started with `kd` with that key can read it. They're unticked at import; tick the ones you want. Request-signing keys (AWS, Cloudinary) and service-account files work the same way. A database proxy that keeps passwords out of the program entirely is on the roadmap (docs/roadmap.md).
- Under `kd`: programs started with a cleaned environment, Go and Rust programs (they ignore the extra certificate), gRPC, Next.js edge middleware, Python run with `-I`, and Docker containers started with `--env-file`. In Docker, use `http://host.docker.internal:7787/<name>` as the base URL.
- Some SDKs check a key's exact format at startup (Clerk, for example) and reject the placeholder.

Report vulnerabilities privately: see [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).

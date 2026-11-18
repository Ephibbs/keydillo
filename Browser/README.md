# keydillo browser

Lets Claude Code sign in to websites, sign up for new accounts and create API keys, without the password or key ever reaching Claude.

It is [Playwright MCP](https://github.com/microsoft/playwright-mcp) (Microsoft, Apache-2.0, used unmodified as an npm dependency) wrapped with keydillo's tools and filters. The keydillo app starts it, ships it inside its signed bundle, and is the only thing it can ask for a password.

## Tools Claude gets

- `list_logins`: saved website logins (name, site, username). No passwords.
- `request_login`: opens keydillo so you can type a login yourself. Claude never sees it.
- `fill_login { login }`: checks the page is on the login's saved site, asks for Touch ID, fills the username, password and 2FA code if one is saved, and submits.
- `fill_new_password { login }`: for sign-ups. Generates a strong password, saves it after Touch ID, and types it into the new-password and confirm fields.
- `start_key_capture`, then `save_new_key { name, host?, project? }`: Claude clicks "Create key" on a provider's site; every new value on the page is hidden from it; `save_new_key` saves the key as a normal keydillo key after Touch ID and returns the `.env` lines.
- `hand_off_to_user { reason }`: for captchas, 2FA prompts, emailed codes and passkeys. keydillo shows a "Claude needs you" window on the Mac and, with a paired iPhone, streams the page to the phone, where taps and typing go back to the browser. Returns when the user taps Done. Claude never sees the stream or what was typed.
- Every other Playwright MCP tool, filtered: passwords and keys show as `••••••••` / `[key hidden …abcd]`, and the network, console and run-code tools are removed.

## How it fits together

1. Claude Code runs `keydillo browser-mcp` (registered by Connect as the `keydillo-browser` MCP server).
2. That asks the app to start the tool, then relays MCP to it over a Unix socket.
3. The app starts the bundled Node runtime with the bundled server, a cleared environment and `--disable-sigusr1`, after checking the app bundle's signature is intact.
4. The tool asks for passwords, saves new ones and saves captured keys over fd 3, a private socketpair only the app holds (`BrowserBroker` in VaultCore). There is no other way to get a password out of keydillo.
5. Logins live in keydillo's Data Protection Keychain group next to API keys, behind Touch ID. They show in the app under **Website logins**.

The same broker protocol (JSON lines: `list`, `secret`, `approvePage`, `saveNew`, `saveKey`, `requestLogin`) is meant to sit behind a Chrome extension's native messaging host too.

## Testing it with the app

1. Build the app from this branch (clean build after changing `Browser/`):
   ```sh
   cd Browser && npm ci && scripts/fetch-node.sh && cd ../App
   xcodegen generate && xcodebuild -project Keydillo.xcodeproj -scheme Keydillo -configuration Release -derivedDataPath build build
   ```
2. Quit the installed keydillo and open `App/build/Build/Products/Release/keydillo.app`.
3. Settings → Connect again, so Claude Code gets `keydillo-browser`. Turn off any plain Playwright MCP server in that session.
4. Ask Claude: "Log in to my GitHub and tell me how many repositories I have." It should call `request_login` (you type the login in keydillo's window), then `fill_login`. Touch ID names the sign-in page the first time.
5. Ask it to create an API key on a provider and save it for a project, or to sign you up somewhere with `fill_new_password`.

## How key pages are spotted

1. Claude calls `start_key_capture` before clicking Create (the tool description tells it to).
2. Automatically: the URL, title, headings, buttons or links mention API keys, tokens, secrets or credentials; the site is a known provider (OpenAI, Anthropic, GitHub, Stripe, ElevenLabs); or Claude clicks a button whose text or description is like "Create key".
3. Backstop: after saving, the tool checks everything it sent Claude this session for any 12-character piece of the key, and warns to rotate it if it finds one.

On a key page, everything already there is the baseline. Anything new that isn't an ordinary word (12+ characters with a digit, or 24+ without spaces) is hidden, in text, input values, attributes and iframes, including keys split across elements. Known key formats are hidden on every page. Screenshots and JavaScript are off on key pages until the key is saved or Claude leaves the page.

## Security status

| Item | Status |
|---|---|
| Passwords only reach the tool over a private pipe from the app, after Touch ID; no command can print one | Done, tested with kd-testbrowser |
| Tool code, dependencies and Node ship inside the signed app; the app refuses to start it if the bundle signature is broken | Done; signature verified on a clean build. macOS App Management also blocks other apps from editing the bundle |
| Node runtime: official build, SHA-256 checked, signed with hardened runtime and no `get-task-allow`, so other processes can't attach; environment cleared; SIGUSR1 debugger off | Done; bundled node tested through the app's host |
| Lock each login to its sign-in page and form endpoint; a new page needs Touch ID that names it | Done, tested |
| Network lock: requests and WebSocket messages carrying the password only go to an approved endpoint | Done, tested (form retarget, `fetch`, WebSocket) |
| Network, console and run-code tools removed; no traces, video or saved sessions; pages can't add tools | Done (config parts not separately tested) |
| Extensions off, `chrome://`, extension and Web Store URLs refused | Done, tested |
| No remote-debugging port (Chrome runs with `--remote-debugging-pipe`) | Verified |
| Chrome's own password saving off | Verified in the profile's Preferences |
| `browser_evaluate` refused on password pages, key pages and signed-in sites | Done, tested |
| Masking in snapshots, results and saved files; screenshots refused while a secret shows as text | Done, tested |
| Clipboard writes, copy/cut keys and downloads blocked | Done, tested |
| Sign-up passwords saved before they are typed; Claude never sees them | Done, tested |
| Cookies on disk: when the app runs the tool, Chrome encrypts them with its own Keychain item instead of Playwright's mock keychain | Done, not verified yet (headless tests still use the mock) |
| The signed-in session itself: Claude can act as you on sites it signed in to | By design |
| `browser_evaluate` works on other pages | By design |
| A password or key drawn in an image or canvas, or transformed by the page, isn't caught by masking | Open (screenshots stay off on key pages) |
| A key shown on a page that doesn't look like a key page, in no known format, before any "create key" click | Open: the exposure check catches it afterwards |
| Captchas, 2FA, emailed codes: `hand_off_to_user` on the Mac or the paired iPhone (frames sealed to a per-session phone key, inputs signed and numbered, one Face ID per session) | Done; protocol tested (5 PhoneLink tests), tool tested end to end with a pretend phone, iPhone screen tested in the simulator over a folder. Not tested over CloudKit or on a device |
| Hand-off live view is a downscaled desktop page with no zoom, about one frame a second over CloudKit | Open |
| The hand-off reason is Claude's text, shown on the phone inside keydillo's own wording | Accepted |
| Passkeys and Google sign-in (blocks automated browsers) | Open |
| Real sites | Open: needs Evan's accounts |
| App size: bundled Node adds about 105 MB (arm64 only for now) | Open |

## Development

```sh
npm test                                   # end-to-end tests: real server, local test sites, fake helper
KD_TESTBROWSER=<path> npm test             # also runs app mode through VaultCore's kd-testbrowser
node tools/claude-check.mjs                # runs `claude -p` against the local site and prints which tools it called
```

Build kd-testbrowser with `swift build --product kd-testbrowser` in `Packages/VaultCore`.

`src/server.mjs` wraps Playwright MCP, `src/guard.mjs` masks and blocks, `src/fill.mjs` signs in, `src/signup.mjs` handles sign-ups, `src/recipes.mjs` knows key formats and provider pages, and `src/app-store.mjs` talks to the app. `helper/` is the old standalone Touch ID helper, kept for running without the app.

MIT. Playwright MCP is Apache-2.0 (see `node_modules/@playwright/mcp/LICENSE`). Node.js's licence ships next to the bundled runtime.

# Where `kd` doesn't work, and what to do instead

`kd` works by sending a program's HTTPS through a small local proxy that only that program can use, and trusting
that proxy's certificate through the usual environment variables (`SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS` and
similar). Programs that ignore those variables, skip the proxy, or outlive `kd` won't get your keys that way.

For almost all of these, the fix is the same: call the API through the key's **local base URL** instead,
`http://localhost:7787/<name>/...`. It's in your `.env` as `<NAME>_BASE_URL`, and keydillo adds the key there with
no certificate involved.

| Situation | What you see | What to do |
|---|---|---|
| Go and Rust | Works when the SDK reads its base-URL variable: `kd` sets `OPENAI_BASE_URL`, `ANTHROPIC_BASE_URL` and the like for this project's keys. Checked: OpenAI's and Anthropic's official Go SDKs, and Rust's `async-openai`. | For SDKs that don't read it, such as `go-openai`, set the base URL in code from `<NAME>_BASE_URL`. |
| gRPC, or Python run with `-I` | A certificate error (`x509: certificate is not trusted`, `CERTIFICATE_VERIFY_FAILED`) | Use the base URL. |
| Next.js edge middleware, workers started with a clean environment | The provider rejects the key (401) | Use the base URL. |
| Docker containers | The provider rejects the key, or `localhost` doesn't connect | Use `http://host.docker.internal:7787/<name>` as the base URL. `--env-file` skips `kd`. |
| Programs that detach and keep running (pm2, `nohup … &`, tmux) | HTTPS calls fail after `kd` exits | Run them in the foreground under `kd`, or use the base URL. |
| Programs not started with `kd` (IDE run buttons, cron, launchd) | The provider rejects the key | Put `kd` in the run command (`kd npm run dev`), or use the base URL. |
| A key the API wants in the body, query or path | `placeholder_misplaced` | Turn on "Allow the key anywhere" for that key in keydillo. |
| Signed requests (AWS, R2, Cloudinary) | Signature errors | Import those secrets as launch-time keys. |
| SDKs that check a key's format at startup (Clerk, for example) | The SDK rejects the placeholder before any request | Keep that key out of keydillo for now. |
| A key with no site set | The provider rejects the key | Open the key in keydillo and set the site it's for. |
| keydillo was quit from the menu | `kd` says keydillo was quit | Open keydillo again. |
| Commands wrapped in `bash -c`, `make`, `just` | Usually fine with `kd` in front of the whole command | Use `kd make dev`, not `make dev`. |

## Launch-time keys

Launch-time keys (database URLs, JWT and signing secrets) are handed to the program as it starts. The program gets
the random placeholder instead of the real value when:

- it loads `.env` with override on (dotenv `override: true`, python-dotenv `override=True`), or reads the file
  itself instead of the environment;
- `kd` runs from a folder above the one with the `.env`, such as a monorepo root. `kd` prints a warning naming
  the file. Run it from the package folder instead.

The placeholder is random, so it can't be guessed. Your app just won't authenticate until it gets the real value.


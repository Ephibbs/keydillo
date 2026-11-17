#!/bin/zsh -f
# Tests kd and the Claude Code hooks (pre-command steering to kd, post-command explanation).
# Needs the keydillo app running. Uses no keys: only checks routing, pass-through and cleanup.
B="$HOME/.local/bin/keydillo"
T=$(mktemp -d); trap 'rm -rf $T' EXIT
pass=0; fail=0
ok() { if eval "$2"; then print "PASS  $1"; ((pass++)); else print "FAIL  $1"; ((fail++)); fi }

mkdir -p $T/proj/sub $T/other
printf '# --- keydillo ---\n# test project\n# --- end keydillo ---\nFOO=keydillo:x\n' > $T/proj/.env
print 'print("hi")' > $T/proj/sub/run.py

ok "kd is on PATH" '[[ -x $HOME/.local/bin/kd ]]'
ok "kd runs a command" '[[ $($HOME/.local/bin/kd /bin/echo hi 2>/dev/null) == hi ]]'

# 4. Pre-command check: programs in a keydillo project need kd; other commands are left alone.
pre() { print -r -- "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$1\"},\"cwd\":\"$2\"}" | "$B" hook 2>&1; print "exit=$?" }
ok "pre: python in a keydillo project is stopped with the kd fix" '[[ $(pre "python3 sub/run.py" $T/proj) == *"kd python3 sub/run.py"*"exit=2"* ]]'
ok "pre: with kd in front it runs" '[[ $(pre "kd python3 sub/run.py" $T/proj) == *"exit=0"* ]]'
ok "pre: npm run dev needs kd" '[[ $(pre "npm run dev" $T/proj/sub) == *"exit=2"* ]]'
ok "pre: npm install doesn't" '[[ $(pre "npm install" $T/proj) == *"exit=0"* ]]'
ok "pre: git and cat don't" '[[ $(pre "git status && cat .env" $T/proj) == *"exit=0"* ]]'
ok "pre: a path into a project counts" '[[ $(pre "python3 $T/proj/sub/run.py" $T/other) == *"exit=2"* ]]'
ok "pre: outside projects nothing is stopped" '[[ $(pre "python3 x.py" $T/other) == *"exit=0"* ]]'

# 5. Post-command check: real providers don't echo the key, so it looks at the command, folder and error.
postc() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2],"tool_response":{"stdout":sys.argv[3],"stderr":""}}))' "$1" "$2" "$3" | "$B" hook post }
ok "post: OpenAI 401 without kd in a project is explained" '[[ $(postc "python3 app.py" $T/proj "openai.AuthenticationError: Error code: 401 - Incorrect API key provided") == *"kd python3 app.py"* ]]'
ok "post: Anthropic invalid x-api-key explained" '[[ -n $(postc "node index.js" $T/proj "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}") ]]'
ok "post: ElevenLabs invalid_api_key explained" '[[ -n $(postc "python3 tts.py" $T/proj "{\"detail\":{\"status\":\"invalid_api_key\"}}") ]]'
ok "post: Gemini key not valid explained" '[[ -n $(postc "python3 g.py" $T/proj "API key not valid. Please pass a valid API key.") ]]'
ok "post: with kd, nothing to say" '[[ -z $(postc "kd python3 app.py" $T/proj "401 Unauthorized") ]]'
ok "post: outside projects, nothing" '[[ -z $(postc "python3 app.py" $T/other "401 Unauthorized") ]]'
ok "post: reading code that mentions 401 isn't flagged" '[[ -z $(postc "cat app.py" $T/proj "raise Exception(\"401 Unauthorized: keydillo:openai\")") ]]'

# 6. kd proxy: plain http:// works; nobody but the proxy can use its per-host TLS listeners.
DEV=~/Desktop/keydillo/App/build/Build/Products/Release/keydillo
export KEYDILLO_TEST_APP_PORT=1 KEYDILLO_TEST_SERVICES='[{"name":"ex","displayName":"ex","project":"t","host":"example.com","baseURL":"x","envVarName":"EX_KEY","baseURLEnvName":"EX_BASE_URL"}]'
python3 -m http.server 18734 --bind 127.0.0.1 >/dev/null 2>&1 & HS=$!; sleep 1
ok "kd: plain http:// to a non-local address works" '[[ $($DEV run -- curl -s -o /dev/null -w "%{http_code}" --max-time 8 http://0.0.0.0:18734/ 2>/dev/null) == 200 ]]'
kill $HS 2>/dev/null
$DEV run -- sh -c 'curl -s -o /dev/null --max-time 8 https://example.com/; sleep 6' >/dev/null 2>&1 & KDP=$!; sleep 3
RUNPID=$(pgrep -f "keydillo run -- sh -c curl" | head -1)
PORTS=($(lsof -nP -a -p $RUNPID -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{split($9,a,":"); print a[2]}'))
refused=1
for p in $PORTS; do
  r=$(curl -s -k --max-time 3 --resolve example.com:$p:127.0.0.1 https://example.com:$p/ -o /dev/null -w "%{http_code}" 2>/dev/null)
  [[ $r == 200 ]] && refused=0
done
ok "kd: an outside program can't use the per-host TLS listener (${#PORTS} ports checked)" '(( ${#PORTS} >= 2 && refused ))'
wait $KDP 2>/dev/null
unset KEYDILLO_TEST_APP_PORT KEYDILLO_TEST_SERVICES

# 7. Other env file names, cd, Go/Rust, the app going away mid-run.
mkdir -p $T/next/web $T/worker
printf '# --- keydillo ---\n# test\n# --- end keydillo ---\nOPENAI_API_KEY=keydillo:x\n' > $T/next/web/.env.local
printf '# --- keydillo ---\n# test\n# --- end keydillo ---\nKEY=keydillo:x\n' > $T/worker/.dev.vars
ok "pre: a Next.js project (.env.local) needs kd" '[[ $(pre "npm run dev" $T/next/web) == *"exit=2"* ]]'
ok "pre: a Workers project (.dev.vars) needs kd" '[[ $(pre "npx wrangler dev" $T/worker) == *"exit=2"* ]]'
ok "pre: cd into a project counts" '[[ $(pre "cd web && npm run dev" $T/next) == *"kd"*"exit=2"* ]]'
ok "pre: go run isn't told to use kd" '[[ $(pre "go run ." $T/proj) == *"exit=0"* ]]'
ok "post: Go auth failure gets the base-URL advice" '[[ $(postc "go run ." $T/proj "401 Unauthorized: invalid api key") == *"BASE_URL"* ]]'
ok "post: certificate error under kd gets the base-URL advice" '[[ $(postc "kd ./server" $T/proj "x509: certificate signed by unknown authority") == *"BASE_URL"* ]]'
export KEYDILLO_TEST_APP_PORT=1 KEYDILLO_TEST_SERVICES='[{"name":"ex","displayName":"ex","project":"t","host":"example.com","baseURL":"x","envVarName":"EX_KEY","baseURLEnvName":"EX_BASE_URL"}]'
start=$(date +%s)
out=$($DEV run -- curl -s --max-time 20 https://example.com/x -H "x-api-key: keydillo:ex" 2>/dev/null)
took=$(( $(date +%s) - start ))
ok "kd: with the app gone, a keyed call fails at once with a clear message (${took}s)" '[[ $out == *"keydillo_not_running"* && $took -lt 5 ]]'
unset KEYDILLO_TEST_APP_PORT KEYDILLO_TEST_SERVICES

# 8. Names in the Touch ID prompt can't be borrowed.
"$B" run --serve-for $$ >/dev/null 2>&1 & SF=$!; sleep 0.5
ok "names: a leftover --serve-for argument doesn't borrow a session's name" '! "$B" whois $SF 2>/dev/null | grep -q "shown as: Claude Code$"'
kill $SF 2>/dev/null

# 9. A key without a host: kd looks inside traffic to likely sites and asks the app to approve the host it saw.
cat > $T/app.py <<'PYEOF'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(sys.argv[2], "w").write(self.headers.get("X-Keydillo-Target-Host", "none") + " " + self.path)
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).handle_request()
PYEOF
python3 $T/app.py 18736 $T/seen & APPP=$!; sleep 0.5
export KEYDILLO_TEST_APP_PORT=18736 KEYDILLO_TEST_SERVICES='[{"name":"example","displayName":"Example","project":"t","host":"","baseURL":"x","envVarName":"EXAMPLE_API_KEY","baseURLEnvName":"EXAMPLE_BASE_URL","hostTokens":["example"]}]'
$DEV run -- curl -s --max-time 8 https://api.example.com/v1/x -H "x-api-key: keydillo:example" >/dev/null 2>&1
ok "kd: a key with no host is offered to the app for approval of the host it was sent to" '[[ $(cat $T/seen 2>/dev/null) == "api.example.com /example/v1/x" ]]'
kill $APPP 2>/dev/null
unset KEYDILLO_TEST_APP_PORT KEYDILLO_TEST_SERVICES

# 10. Launch-time keys: kd puts the real value in the program's environment; .env loaders keep it.
mkdir -p $T/web/src
printf '# --- keydillo ---\n# test\n# --- end keydillo ---\nJWT_SECRET=keydillo:jwt-secret:start-with-keydillo-run\nPORT=3000\n' > $T/web/.env
export KEYDILLO_TEST_SERVICES='[{"name":"jwt-secret","displayName":"JWT secret","project":"t","host":"","baseURL":"x","envVarName":"JWT_SECRET","baseURLEnvName":"X","launchTime":true}]'
export KEYDILLO_TEST_LAUNCH_VALUES='{"jwt-secret":"s3cret-from-keychain"}' KEYDILLO_TEST_APP_PORT=1
ok "launch-time: kd gives the program the real value" '[[ $(cd $T/web/src && $DEV run -- sh -c "echo \$JWT_SECRET" 2>/dev/null) == "s3cret-from-keychain" ]]'
PY=$HOME/Desktop/keydillo-breakers/.venv/bin/python
if [[ -x $PY ]]; then
  ok "launch-time: python-dotenv keeps kd's value instead of the placeholder" '[[ $(cd $T/web && $DEV run -- $PY -c "from dotenv import load_dotenv; load_dotenv(); import os; print(os.environ[\"JWT_SECRET\"])" 2>/dev/null) == "s3cret-from-keychain" ]]'
fi
export KEYDILLO_TEST_LAUNCH_VALUES='{}'
ok "launch-time: if it isn't approved, kd says so" '[[ $(cd $T/web && $DEV run -- true 2>&1) == *"JWT_SECRET wasn"* ]]'
unset KEYDILLO_TEST_SERVICES KEYDILLO_TEST_LAUNCH_VALUES KEYDILLO_TEST_APP_PORT

# 11. After you quit keydillo yourself, kd doesn't reopen it. (Stops the running app for a moment, then restarts it.)
QM="$HOME/Library/Application Support/keydillo/quit-by-user"
launchctl kill TERM gui/$(id -u)/com.studiokillswitch.keydillo.agent 2>/dev/null; sleep 2
touch "$QM"
out=$("$B" run -- true 2>&1); running=$(pgrep -f "MacOS/keydillo$")
ok "quit: kd says keydillo was quit and doesn't reopen it" '[[ $out == *"keydillo was quit"* && -z $running ]]'
rm -f "$QM"; launchctl kickstart gui/$(id -u)/com.studiokillswitch.keydillo.agent 2>/dev/null; sleep 3
ok "quit: once keydillo is open again, kd works" '"$B" run -- true 2>/dev/null'

print "\n$pass passed, $fail failed"
exit $fail
